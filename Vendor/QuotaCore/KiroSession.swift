import Foundation
import SQLite3

/// Reuses the existing device registration. No login UI, AI request, or logout.
actor KiroSession {
    static let shared = KiroSession()
    private let key = "kirocli:odic:token"
    private var requests:[String:Task<String,Error>] = [:]
    func token(database:String,force:Bool = false,send:@escaping HTTPSend = HTTP.send) async throws->String {
        if let request = requests[database] {return try await request.value}
        let request = Task {try await renew(database:database,force:force,send:send)}
        requests[database] = request;defer {requests.removeValue(forKey:database)}
        return try await request.value
    }
    private func renew(database:String,force:Bool,send:HTTPSend) async throws->String {
        guard let raw = SQLiteRead.rows(inFile:database,query:"SELECT value FROM auth_kv WHERE key = '\(key)'",immutable:false).first?.first ?? nil,
              var saved = ProviderJSON.object(Data(raw.utf8)) as? [String:Any],let access = saved["access_token"] as? String else{throw ProviderError.unauthorized}
        if !force,let text = saved["expires_at"] as? String,let expiry = Self.date(text),expiry.timeIntervalSinceNow>60 {return access}
        guard let refresh = saved["refresh_token"] as? String,
              let registrationRaw = SQLiteRead.rows(inFile:database,query:"SELECT value FROM auth_kv WHERE key = 'kirocli:odic:device-registration'",immutable:false).first?.first ?? nil,
              let registration = ProviderJSON.object(Data(registrationRaw.utf8)) as? [String:Any],
              let client = registration["client_id"] as? String,let secret = registration["client_secret"] as? String,
              let region = saved["region"] as? String,region.range(of:"^[a-z]{2}-[a-z]+-[0-9]+$",options:.regularExpression) != nil,
              let url = URL(string:"https://oidc.\(region).amazonaws.com/token") else{throw ProviderError.unauthorized}
        let body = try JSONSerialization.data(withJSONObject:["clientId":client,"clientSecret":secret,"refreshToken":refresh,"grantType":"refresh_token"])
        let response = try await send("POST",url,["Content-Type":"application/json"],body,20)
        if response.status == 400 || response.status == 401 {throw ProviderError.unauthorized}
        _ = try response.requireOK()
        guard let result = ProviderJSON.object(response.data) as? [String:Any],let token = result["accessToken"] as? String,!token.isEmpty,
              let seconds = result["expiresIn"] as? Double,seconds.isFinite,seconds>0 else{throw ProviderError.badResponse}
        saved["access_token"] = token;saved["expires_at"] = ISO8601DateFormatter().string(from:Date().addingTimeInterval(seconds))
        if let next = result["refreshToken"] as? String,!next.isEmpty {saved["refresh_token"] = next}
        let updated = String(decoding:try JSONSerialization.data(withJSONObject:saved),as:UTF8.self)
        if try Self.replace(database:database,key:key,old:raw,new:updated) {return token}
        // Another Kiro process renewed first: use its result without overwriting it.
        guard let latest = SQLiteRead.rows(inFile:database,query:"SELECT value FROM auth_kv WHERE key = '\(key)'",immutable:false).first?.first ?? nil,
              let value = ProviderJSON.object(Data(latest.utf8)) as? [String:Any],let current = value["access_token"] as? String else{throw ProviderError.unauthorized}
        return current
    }
    private static func date(_ text:String)->Date? {
        let f = ISO8601DateFormatter();f.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        return f.date(from:text) ?? ISO8601DateFormatter().date(from:text)
    }
    private static func replace(database:String,key:String,old:String,new:String)throws->Bool {
        var db:OpaquePointer?
        guard sqlite3_open_v2(database,&db,SQLITE_OPEN_READWRITE,nil) == SQLITE_OK else{sqlite3_close(db);throw ProviderError.badResponse}
        defer {sqlite3_close(db)}
        sqlite3_busy_timeout(db,2000)
        var statement:OpaquePointer?
        guard sqlite3_prepare_v2(db,"UPDATE auth_kv SET value = ? WHERE key = ? AND value = ?",-1,&statement,nil) == SQLITE_OK else{throw ProviderError.badResponse}
        defer {sqlite3_finalize(statement)}
        let transient = unsafeBitCast(-1,to:sqlite3_destructor_type.self)
        sqlite3_bind_text(statement,1,new,-1,transient);sqlite3_bind_text(statement,2,key,-1,transient);sqlite3_bind_text(statement,3,old,-1,transient)
        guard sqlite3_step(statement) == SQLITE_DONE else{throw ProviderError.badResponse}
        return sqlite3_changes(db) == 1
    }
}
