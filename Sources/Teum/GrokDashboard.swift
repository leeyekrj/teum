import Foundation
import QuotaCore

enum GrokNative {
    static func file(_ directory:URL)->URL {directory.appendingPathComponent("grok-native.json")}
    static func enabled(directory:URL)->Bool {
        guard let data = try? Data(contentsOf:file(directory)),let value = try? JSONDecoder().decode(Bool.self,from:data) else{return false}
        return value
    }
    static func activate(directory:URL) async throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try JSONEncoder().encode(true).write(to:file(directory),options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file(directory).path)
        await GrokDashboard.disconnect(directory:directory)
    }
    static func connect(directory:URL) async throws {
        _ = try await GrokBot.dashboardUsage()
        try await activate(directory:directory)
    }
    static func disconnect(directory:URL) {try? FileManager.default.removeItem(at:file(directory))}
}

/// Reads quota in Aevo's existing authenticated first-party page. Browser
/// cookies never leave Aevo. No Grok prompts or webhook client are invoked.
enum GrokDashboard {
    enum Failure:Error {case unavailable,login,forbidden,transient,response,timeout,closed}
    struct Link:Codable {var jobID:String}
    static var executable:String? {ConnectionAction.executable("aevo-agent")}
    static func file(_ directory:URL)->URL {directory.appendingPathComponent("grok-dashboard.json")}
    static func link(_ directory:URL)->Link? {(try? Data(contentsOf:file(directory))).flatMap{try? JSONDecoder().decode(Link.self,from:$0)}}
    static func connected(directory:URL)->Bool {link(directory) != nil && executable != nil}
    static let script = #"await aevo.step('공식 Grok 대시보드의 주간 사용량 확인'); await aevo.navigate('https://grok.com/dashboard/'); const page=await aevo.read(); const quota=await aevo.evaluate('const r=await fetch("/dashboard/api/dashboard/v2/usage-status?scope=user"); if(!r.ok) return {status:r.status};const j=await r.json();return {status:r.status,availability:j.availability,weeklyIncludedUsage:j.weeklyIncludedUsage};'); return quota;"#

    static func connect(directory:URL) async throws->UsageSnapshot {
        let old = link(directory)
        let result = try await run(job:nil)
        let snapshot:UsageSnapshot
        do {snapshot = try parse(result)}
        catch {if let id = result["jobId"] as? String {await finish(id)};throw error}
        guard let id = result["jobId"] as? String else{throw Failure.response}
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try JSONEncoder().encode(Link(jobID:id)).write(to:file(directory),options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file(directory).path)
        if let old,old.jobID != id {await finish(old.jobID)}
        return snapshot
    }
    static func read(directory:URL) async throws->UsageSnapshot {
        guard let link = link(directory) else{throw Failure.unavailable}
        do {
            let result = try await run(job:link.jobID)
            let snapshot = try parse(result)
            return snapshot
        } catch Failure.closed {return try await connect(directory:directory)}
    }
    static func disconnect(directory:URL) async {
        if let old = link(directory) {await finish(old.jobID)}
        try? FileManager.default.removeItem(at:file(directory))
    }
    static func parse(_ result:[String:Any])throws->UsageSnapshot {
        var node = result
        // CLI envelope, SDK evaluate envelope, then the bounded quota body.
        for _ in 0..<4 {
            if node["status"] is Int {break}
            if let next = node["value"] as? [String:Any] {node = next}
            else if let next = node["result"] as? [String:Any] {node = next}
            else {throw Failure.response}
        }
        guard let status = node["status"] as? Int else{throw Failure.response}
        if status == 401 {throw Failure.login}
        if status == 403 {throw Failure.forbidden}
        if status == 429 || status>=500 {throw Failure.transient}
        guard status == 200,node["availability"] as? String == "available",
              let weekly = node["weeklyIncludedUsage"] as? [String:Any],
              let used = weekly["usedCents"] as? Double,let budget = weekly["budgetCents"] as? Double,
              used.isFinite,budget.isFinite,used >= 0,budget > 0,
              let start = date(weekly["periodStart"] as? String),let reset = date(weekly["resetsAt"] as? String),reset > start
        else {throw Failure.response}
        return UsageSnapshot(windows:[UsageWindow(title:"Grok weekly usage",usedPercent:used/budget*100,resetsAt:reset,windowSeconds:604800)])
    }
    private static func date(_ text:String?)->Date? {
        guard let text else{return nil}
        let f = ISO8601DateFormatter();f.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        return f.date(from:text) ?? ISO8601DateFormatter().date(from:text)
    }
    private static func run(job:String?) async throws->[String:Any] {
        guard let executable else{throw Failure.unavailable}
        var args = ["run","--text"]
        if let job {args += ["--job",job]}
        else {args += ["--title","Teum · Grok 사용량 연결","--goal","Teum과 teum-cli가 연결된 동안 공식 Grok 대시보드의 주간 사용량과 리셋만 주기적으로 읽기. 질문 전송·계정 변경 없음. 연결 해제 시 종료."]}
        args += ["-e",script]
        let data = try await command(executable,args:args)
        guard let line = String(data:data,encoding:.utf8)?.split(separator:"\n").first,
              let json = String(line).data(using:.utf8),let object = try? JSONSerialization.jsonObject(with:json) as? [String:Any]
        else {throw Failure.response}
        if let rawError = object["error"] {
            let error = String(describing:rawError).lowercased()
            if ["job is done","job is closed","job not found","job_not_found","job_closed"].contains(where:error.contains) {throw Failure.closed}
            throw Failure.response
        }
        return object
    }
    private static func finish(_ id:String) async {
        guard let executable else{return}
        _ = try? await command(executable,args:["task",id,"--done","Teum에서 공식 Grok 주간 사용량과 리셋 정보를 확인했습니다."])
    }
    private static func command(_ executable:String,args:[String]) async throws->Data {
        try await Task.detached(priority:.utility) {
            let p = Process();p.executableURL = URL(fileURLWithPath:executable);p.arguments = args
            let out = Pipe();p.standardOutput = out;p.standardError = FileHandle.nullDevice
            try p.run()
            let timeout = DispatchWorkItem {if p.isRunning {p.terminate()}}
            DispatchQueue.global().asyncAfter(deadline:.now()+45,execute:timeout)
            let data = out.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit();timeout.cancel()
            guard !data.isEmpty else{throw Failure.response}
            return data
        }.value
    }
    static func message(_ error:Error)->String {
        switch error as? Failure {
        case .unavailable:return "Aevo를 설치하고 Grok 대시보드에 로그인한 뒤 연결해 주세요."
        case .login:return "Grok 대시보드 로그인이 필요해요. Aevo에서 로그인한 뒤 재연결해 주세요."
        case .forbidden:return "Grok 대시보드 접근이 거부됐어요(403). Aevo에서 보안 확인·접근 권한을 확인해 주세요. 연결은 유지됩니다."
        case .transient:return "Grok 서버가 잠시 응답하지 않거나 요청을 제한했어요. 연결을 유지하고 다음 새로고침에 다시 확인합니다."
        default:return "Grok 사용량을 일시적으로 읽지 못했어요. 연결과 마지막 기록은 유지됩니다. 다음 새로고침에서 다시 확인합니다."
        }
    }
}
