import Foundation
import SQLite3
@testable import QuotaCore

final class KiroSessionTests {
    private func database(expired:Bool = true)throws->URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        let url = dir.appendingPathComponent("test.sqlite3")
        var db:OpaquePointer?;sqlite3_open(url.path,&db);defer{sqlite3_close(db)}
        sqlite3_exec(db,"CREATE TABLE auth_kv (key TEXT PRIMARY KEY,value TEXT)",nil,nil,nil)
        try put(db,key:"kirocli:odic:token",object:["access_token":"fixture-old","refresh_token":"fixture-refresh","region":"us-east-1","expires_at":ISO8601DateFormatter().string(from:Date().addingTimeInterval(expired ? -10 : 3600))])
        try put(db,key:"kirocli:odic:device-registration",object:["client_id":"fixture-client","client_secret":"fixture-secret"])
        return url
    }
    private func put(_ db:OpaquePointer?,key:String,object:[String:Any])throws {
        let text = String(decoding:try JSONSerialization.data(withJSONObject:object),as:UTF8.self)
        var s:OpaquePointer?;sqlite3_prepare_v2(db,"INSERT OR REPLACE INTO auth_kv VALUES (?,?)",-1,&s,nil);defer{sqlite3_finalize(s)}
        let transient = unsafeBitCast(-1,to:sqlite3_destructor_type.self)
        sqlite3_bind_text(s,1,key,-1,transient);sqlite3_bind_text(s,2,text,-1,transient)
        XCTAssertEqual(sqlite3_step(s),SQLITE_DONE)
    }
    func testFreshSessionMakesNoNetworkRequest() async throws {
        let url = try database(expired:false);defer{try? FileManager.default.removeItem(at:url.deletingLastPathComponent())}
        let result = try await KiroSession.shared.token(database:url.path,send:{_,_,_,_,_ in XCTFail("fresh token sent network request");throw ProviderError.badResponse})
        XCTAssertEqual(result,"fixture-old")
    }
    func testRenewalPersistsAccessAndRotatedRefreshToken() async throws {
        let url = try database();defer{try? FileManager.default.removeItem(at:url.deletingLastPathComponent())}
        let result = try await KiroSession.shared.token(database:url.path,send:{method,url,_,body,_ in
            XCTAssertEqual(method,"POST");XCTAssertEqual(url.absoluteString,"https://oidc.us-east-1.amazonaws.com/token")
            let request = try JSONSerialization.jsonObject(with:body!) as! [String:String]
            XCTAssertEqual(request["grantType"],"refresh_token");XCTAssertEqual(request["clientId"],"fixture-client")
            return HTTPResponse(status:200,data:try JSONSerialization.data(withJSONObject:["accessToken":"fixture-new","refreshToken":"fixture-next","expiresIn":3600]))
        })
        XCTAssertEqual(result,"fixture-new")
        let raw = SQLiteRead.rows(inFile:url.path,query:"SELECT value FROM auth_kv WHERE key='kirocli:odic:token'",immutable:false)[0][0]!
        let stored = try JSONSerialization.jsonObject(with:Data(raw.utf8)) as! [String:Any]
        XCTAssertEqual(stored["refresh_token"] as? String,"fixture-next")
        XCTAssertNotNil(stored["expires_at"])
    }
    func testRejectedRenewalPreservesExistingLogin() async throws {
        let url = try database();defer{try? FileManager.default.removeItem(at:url.deletingLastPathComponent())}
        let before = SQLiteRead.rows(inFile:url.path,query:"SELECT value FROM auth_kv",immutable:false)
        do {_ = try await KiroSession.shared.token(database:url.path,send:{_,_,_,_,_ in HTTPResponse(status:401,data:Data())});XCTFail("accepted rejected refresh")}
        catch {XCTAssertTrue(error is ProviderError)}
        XCTAssertEqual(before,SQLiteRead.rows(inFile:url.path,query:"SELECT value FROM auth_kv",immutable:false))
    }
    func testConcurrentCLIRenewalIsNotOverwritten() async throws {
        let url = try database();defer{try? FileManager.default.removeItem(at:url.deletingLastPathComponent())}
        let result = try await KiroSession.shared.token(database:url.path,send:{_,_,_,_,_ in
            var db:OpaquePointer?;sqlite3_open(url.path,&db);defer{sqlite3_close(db)}
            sqlite3_exec(db,"UPDATE auth_kv SET value = '{\"access_token\":\"fixture-cli-winner\"}' WHERE key='kirocli:odic:token'",nil,nil,nil)
            return HTTPResponse(status:200,data:Data("{\"accessToken\":\"fixture-loser\",\"expiresIn\":3600}".utf8))
        })
        XCTAssertEqual(result,"fixture-cli-winner")
    }
    func testCommittedWALTokenIsVisible() async throws {
        let url = try database();defer{try? FileManager.default.removeItem(at:url.deletingLastPathComponent())}
        var db:OpaquePointer?;sqlite3_open(url.path,&db);defer{sqlite3_close(db)}
        sqlite3_exec(db,"PRAGMA journal_mode=WAL",nil,nil,nil)
        try put(db,key:"kirocli:odic:token",object:["access_token":"fixture-wal","expires_at":ISO8601DateFormatter().string(from:Date().addingTimeInterval(3600))])
        let result = try await KiroSession.shared.token(database:url.path,send:{_,_,_,_,_ in XCTFail("ignored WAL token");throw ProviderError.badResponse})
        XCTAssertEqual(result,"fixture-wal")
    }
}

private enum CheckLog {
    static let lock = NSLock()
    static var failures:[String] = []
    static func record(_ ok:Bool,_ message:String) {lock.lock();defer{lock.unlock()};if !ok {failures.append(message)}}
}
private func XCTAssertEqual<T:Equatable>(_ a:T,_ b:T) {CheckLog.record(a == b,"equality failed")}
private func XCTAssertTrue(_ value:Bool) {CheckLog.record(value,"condition failed")}
private func XCTAssertNotNil<T>(_ value:T?) {CheckLog.record(value != nil,"missing value")}
private func XCTFail(_ message:String) {CheckLog.record(false,message)}
@main private struct KiroSessionChecks {
    static func main() async {
        do {
            let tests = KiroSessionTests()
            try await tests.testFreshSessionMakesNoNetworkRequest()
            try await tests.testRenewalPersistsAccessAndRotatedRefreshToken()
            try await tests.testRejectedRenewalPreservesExistingLogin()
            try await tests.testConcurrentCLIRenewalIsNotOverwritten()
            try await tests.testCommittedWALTokenIsVisible()
        } catch {CheckLog.record(false,"unexpected fixture error")}
        if CheckLog.failures.isEmpty {print("PASS: 5 isolated Kiro renewal scenarios")}
        else {print("FAIL:",CheckLog.failures);exit(1)}
    }
}
