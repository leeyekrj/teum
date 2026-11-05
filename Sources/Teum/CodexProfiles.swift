import Foundation

enum CodexProfiles {
    /// Profiles are credential stores, rather than copies of the CLI binary.
    /// Symlinked stores are one profile; separate stores retain their identity.
    static func discover(home:URL = FileManager.default.homeDirectoryForCurrentUser)->[Stream] {
        let folders = (try? FileManager.default.contentsOfDirectory(at:home,includingPropertiesForKeys:nil)) ?? []
        let candidates = folders.filter{$0.lastPathComponent == ".codex" || $0.lastPathComponent.hasPrefix(".codex-")}.sorted {
            if $0.lastPathComponent == ".codex" {return true}
            if $1.lastPathComponent == ".codex" {return false}
            return $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        var stores = Set<String>()
        return candidates.compactMap {folder in
            let auth = folder.appendingPathComponent("auth.json")
            guard FileManager.default.fileExists(atPath:auth.path),stores.insert(auth.resolvingSymlinksInPath().standardizedFileURL.path).inserted else{return nil}
            let profile = folder.lastPathComponent == ".codex" ? "" : String(folder.lastPathComponent.dropFirst(7))
            guard folder.lastPathComponent == ".codex" || !profile.isEmpty,profile != ".",profile != ".." else{return nil}
            let id = profile.isEmpty ? "codex" : "codex-"+profile
            if let known = Stream.defaults.first(where:{$0.id == id}) {return known}
            return Stream(id:id,name:"코덱스 "+profile,source:"codex",profile:profile)
        }
    }
    static func initial(home:URL = FileManager.default.homeDirectoryForCurrentUser)->Preferences {
        var prefs = Preferences()
        let found = discover(home:home)
        let profiles = found.isEmpty ? [Stream.defaults[1]] : found
        prefs.streams.removeAll{$0.source == "codex"}
        prefs.streams.insert(contentsOf:profiles,at:min(1,prefs.streams.count))
        return prefs
    }
}
