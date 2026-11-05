import Foundation
import Darwin

// Shares the CLI's lock and JSON schema, without depending on a source checkout
// or on Python being installed on the recipient's Mac.
enum SessionWatchStore {
    static func cancel(_ id:String,directory:URL,now:Date = .now)->Bool {
        let lock = directory.appendingPathComponent("session-watches.lock")
        let fd = Darwin.open(lock.path,O_RDWR | O_CREAT,0o600)
        guard fd >= 0 else{return false}
        defer {Darwin.close(fd)}
        guard flock(fd,LOCK_EX) == 0 else{return false}
        defer {_ = flock(fd,LOCK_UN)}
        let file = directory.appendingPathComponent("session-watches.json")
        guard let data = try? Data(contentsOf:file),
              var state = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
              var rules = state["rules"] as? [[String:Any]],
              let index = rules.firstIndex(where:{$0["id"] as? String == id}) else{return false}
        guard rules[index]["state"] as? String == "armed" else{return true}
        let time = now.timeIntervalSince1970
        rules[index]["state"] = (rules[index]["expires_at"] as? Double ?? 0) <= time ? "expired" : "cancelled"
        rules[index]["finished_at"] = time;state["rules"] = rules
        guard let result = try? JSONSerialization.data(withJSONObject:state,options:[.prettyPrinted,.sortedKeys]) else{return false}
        let temp = directory.appendingPathComponent(".session-watches-"+UUID().uuidString+".tmp")
        guard FileManager.default.createFile(atPath:temp.path,contents:result,attributes:[.posixPermissions:0o600]) else{return false}
        defer {try? FileManager.default.removeItem(at:temp)}
        return Darwin.rename(temp.path,file.path) == 0
    }
}
