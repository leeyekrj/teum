import Foundation
import Combine
import QuotaCore

enum TokenPeriod:Int,CaseIterable {case today = 1,week = 7,month = 30,quarter = 90,all = 0
    var title:String {self == .today ? "오늘" : self == .all ? "전체" : "\(rawValue)일"}
}
enum TokenText {
    static func count(_ n:Int)->String {
        let value = Double(n)
        if n>=1_000_000_000 {return String(format:"%.2fB",value/1_000_000_000)}
        if n>=1_000_000 {return String(format:"%.1fM",value/1_000_000)}
        if n>=1_000 {return String(format:"%.1fK",value/1_000)}
        return String(n)
    }
}
struct TokenModelRow:Identifiable {
    var source:CostSource
    var model:String
    var entry:ArchiveEntry
    var id:String {source.rawValue+"|"+model}
}
struct TokenHour:Identifiable {
    var hour:Int
    var tokens:Int
    var id:Int {hour}
}
struct TokenReport {
    var hourly:[TokenHour] = []
    var total = ArchiveEntry()
    var models:[TokenModelRow] = []
    var daily:[ArchiveSummary.Day] = []
    var projects:[ProjectSummary] = []
    var activeDays = 0
    var sessions = 0
}
struct TokenHistoryCache:Codable,Sendable {
    var archive = UsageArchive()
    var projects = ProjectArchive()
    var roots:[String] = []
    var fullHistoryScan:Bool?
    var importedArchiveDays:Int?
    var importedUsageScopeDays:Int?

    // Read only accumulated counters. Merging takes the larger day/source/model
    // reading, so a rescan or a repeated import never counts a session twice.
    mutating func importArchive(directory:URL) {
        let decoder = JSONDecoder();decoder.dateDecodingStrategy = .secondsSince1970
        if let data = try? Data(contentsOf:directory.appendingPathComponent("usage-archive.json")),let old = try? decoder.decode(UsageArchive.self,from:data) {
            let last = archive.lastScan
            archive.merge(old.days,scannedAt:last ?? .distantPast,full:false)
            archive.lastScan = last
            importedArchiveDays = old.days.count
        }
        if let data = try? Data(contentsOf:directory.appendingPathComponent("project-archive.json")),let old = try? decoder.decode(ProjectArchive.self,from:data) {
            let last = projects.lastScan
            let refs = old.projects.mapValues{ProjectRef(key:$0.key,name:$0.name,repo:$0.repo,root:$0.root)}
            var fresh = old.days
            for (day,items) in old.days {for (project,sources) in items {for (source,modes) in sources {for (mode,entry) in modes {
                if let kept = projects.days[day]?[project]?[source]?[mode],kept.allTokens>=entry.allTokens {fresh[day]?[project]?[source]?[mode] = kept}
            }}}}
            projects.merge(fresh,infos:refs,scannedAt:last ?? .distantPast,full:false)
            projects.lastScan = last
        }
    }
    /// Import only verified local-log aggregates. Codex input already includes its cache.
    /// Preserve the larger day/source/model total instead of adding duplicate histories.
    mutating func importUsageScope(file:URL) {
        guard let data = try? Data(contentsOf:file),let rows = try? JSONDecoder().decode([ScopeDay].self,from:data) else{return}
        var fresh:ArchiveDays = [:]
        for row in rows where row.isLegacyUnverified == false {
            let source:String
            if row.source == "claudeLocalProjectLog" {source = CostSource.claudeCode.rawValue}
            else if row.source == "codexLocalSessionLog" {source = CostSource.codexCLI.rawValue}
            else {continue}
            let u = row.usage
            let cache = row.source == "codexLocalSessionLog" ? u.cachedInputTokens ?? 0 : u.cacheReadTokens ?? 0
            let input = row.source == "codexLocalSessionLog" ? max(0,u.inputTokens-cache) : u.inputTokens
            let entry = ArchiveEntry(input:input,output:u.outputTokens,cacheRead:cache,cacheWrite:u.cacheCreationTokens ?? 0)
            guard entry.allTokens>0,entry.allTokens == u.totalTokens,row.dayStart.isFinite else{continue}
            let day = UsageArchive.dayKey(Date(timeIntervalSinceReferenceDate:row.dayStart))
            if entry.allTokens > (fresh[day]?[source]?[row.model]?.allTokens ?? 0) {fresh[day,default:[:]][source,default:[:]][row.model] = entry}
        }
        let last = archive.lastScan
        archive.merge(fresh,scannedAt:last ?? .distantPast,full:false);archive.lastScan = last
        importedUsageScopeDays = fresh.count
    }
}

private struct ScopeDay:Decodable {
    struct Usage:Decodable {
        let inputTokens:Int;let outputTokens:Int;let totalTokens:Int
        let cachedInputTokens:Int?;let cacheReadTokens:Int?;let cacheCreationTokens:Int?
    }
    let dayStart:Double;let model:String;let source:String;let isLegacyUnverified:Bool;let usage:Usage
}

@MainActor final class TokenHistoryStore:ObservableObject {
    @Published var cache = TokenHistoryCache() {didSet {cachedReport = nil}}
    @Published var reading = false
    @Published var openingCache = false
    @Published var error:String?
    @Published var period:TokenPeriod = .week
    @Published var breakdown = "models"
    @Published var selectedMonth:String?
    private var cachedReport:(key:String,value:TokenReport)?
    private(set) var reportBuilds = 0
    private let file:URL
    private let fixture:Bool
    private var cacheLoaded = false
    init(directory:URL,fixture:Bool = false,deferred:Bool = false) {
        self.fixture = fixture;file = directory.appendingPathComponent("token-history.json")
        if fixture {cache = Self.sample();cacheLoaded = true;return}
        if deferred {openingCache = true;return}
        cache = Self.readCache(file);cacheLoaded = true
    }
    nonisolated private static func readCache(_ file:URL)->TokenHistoryCache {
        var cache = TokenHistoryCache()
        let decoder = JSONDecoder();decoder.dateDecodingStrategy = .secondsSince1970
        if let data = try? Data(contentsOf:file),let saved = try? decoder.decode(TokenHistoryCache.self,from:data) {cache = saved}
        // Recovered UsageScope aggregates are already in the owned cache.
        // Never open another app's protected container from the UI thread.
        cache.importArchive(directory:FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/QuotaBar"))
        return cache
    }
    var lastRead:Date? {cache.archive.lastScan}
    var hasData:Bool {cache.archive.days.values.contains{$0.values.contains{$0.values.contains{$0.allTokens>0}}}}
    func load(streams:[Stream],force:Bool = false) async {
        guard !fixture,!reading else{return}
        if !cacheLoaded {
            reading = true
            let file = file
            cache = await Task.detached(priority:.utility) {Self.readCache(file)}.value
            cacheLoaded = true;openingCache = false;reading = false
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let empty = file.deletingLastPathComponent().appendingPathComponent("no-token-source")
        let claude = streams.contains{$0.source == "claude" && $0.connected != false} ? home.appendingPathComponent(".claude/projects") : empty
        var seen = Set<String>()
        let codex = streams.filter{$0.source == "codex" && $0.connected != false}.map {
            home.appendingPathComponent($0.profile.isEmpty ? ".codex/sessions" : ".codex-\($0.profile)/sessions").resolvingSymlinksInPath().standardizedFileURL
        }.filter{seen.insert($0.path).inserted}
        let paths = CostPaths(claudeProjects:claude,codexSessions:codex.first ?? empty,additionalCodexSessions:Array(codex.dropFirst()),openCodeDatabase:home.appendingPathComponent(".local/share/opencode/opencode.db"))
        let roots = ([claude]+codex+[paths.openCodeDatabase]).map(\.path).sorted()
        if !force,cache.fullHistoryScan == true,roots == cache.roots,let lastRead,Date().timeIntervalSince(lastRead)<300 {return}
        reading = true;error = nil
        let previous = cache;let file = self.file
        let result = await Task.detached(priority:.utility) {()->(TokenHistoryCache,String?) in
            let now = Date();let cal = Calendar.current
            let oldest = cal.date(byAdding:.day,value:-89,to:cal.startOfDay(for:now)) ?? now
            let full = previous.roots != roots || previous.fullHistoryScan != true
            let cutoff = full ? Date.distantPast : previous.archive.incrementalCutoff() ?? oldest
            let scan = CostEstimator.archiveScan(paths:paths,since:cutoff,now:now)
            CostEstimator.resetCache()
            var result = previous
            let decoder = JSONDecoder();decoder.dateDecodingStrategy = .secondsSince1970
            if let data = try? Data(contentsOf:file),let latest = try? decoder.decode(TokenHistoryCache.self,from:data) {result = latest}
            result.importArchive(directory:home.appendingPathComponent("Library/Application Support/QuotaBar"))
            result.archive.merge(scan.days,scannedAt:now,full:full)
            result.projects.merge(scan.projects,infos:scan.projectRefs,scannedAt:now,full:full)
            result.roots = roots
            result.fullHistoryScan = true
            do {
                try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
                let encoder = JSONEncoder();encoder.dateEncodingStrategy = .secondsSince1970
                try encoder.encode(result).write(to:file,options:.atomic)
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
                return(result,nil)
            } catch {return(result,"집계는 완료했지만 기록을 저장하지 못했어요.")}
        }.value
        cache = result.0;error = result.1;reading = false
    }
    var months:[String] {Array(Set(cache.archive.days.keys.map{String($0.prefix(7))})).sorted(by:>)}
    func report(now:Date = .now)->TokenReport {
        let key = "\(period.rawValue)|\(selectedMonth ?? "")|\(UsageArchive.dayKey(now))|\(TimeZone.current.identifier)"
        if let cachedReport,cachedReport.key == key {return cachedReport.value}
        let value = Self.report(cache,period:period,now:now,month:selectedMonth)
        reportBuilds += 1
        cachedReport = (key,value);return value
    }
    static func report(_ cache:TokenHistoryCache,period:TokenPeriod,now:Date = .now,month:String? = nil)->TokenReport {
        let cal = Calendar.current;let end = cal.startOfDay(for:now)
        let start = period == .all ? min(end,cache.archive.firstDay ?? end) : cal.date(byAdding:.day,value:-(period.rawValue-1),to:end) ?? end
        let monthStart = month.flatMap{UsageArchive.date(forKey:$0+"-01")}
        let lower = monthStart ?? start
        let upper = monthStart.flatMap{cal.date(byAdding:.month,value:1,to:$0)}.flatMap{cal.date(byAdding:.day,value:-1,to:$0)}.map{min(end,$0)} ?? end
        let range = cache.archive.summary(from:lower,to:upper)
        var report = TokenReport();var entries:[String:TokenModelRow] = [:]
        report.daily = range.days;report.activeDays = range.activeDays
        var hours = Array(repeating:0,count:24)
        for sources in cache.projects.days[UsageArchive.dayKey(end)]?.values ?? Dictionary<String,[String:[String:ProjectDay]]>().values {
            for modes in sources.values {for bucket in modes.values {for (hour,tokens) in bucket.hours.prefix(24).enumerated() {hours[hour] += tokens}}}
        }
        report.hourly = hours.enumerated().map{TokenHour(hour:$0.offset,tokens:$0.element)}
        for day in range.days {
            for (sourceName,models) in cache.archive.days[UsageArchive.dayKey(day.day)] ?? [:] {
                guard let source = CostSource(rawValue:sourceName) else{continue}
                for (model,e) in models {
                    guard e.allTokens>0 else{continue}
                    report.total.input += e.input;report.total.output += e.output
                    report.total.cacheRead += e.cacheRead;report.total.cacheWrite += e.cacheWrite
                    let key = sourceName+"|"+model
                    var row = entries[key] ?? TokenModelRow(source:source,model:model,entry:ArchiveEntry())
                    row.entry.input += e.input;row.entry.output += e.output
                    row.entry.cacheRead += e.cacheRead;row.entry.cacheWrite += e.cacheWrite
                    // Only OpenCode's own recorded amount is exposed. Estimated
                    // list-rate dollars are never presented as an API bill.
                    if source == .openCode {row.entry.usd += e.usd}
                    entries[key] = row
                }
            }
        }
        report.models = entries.values.sorted{$0.entry.allTokens>$1.entry.allTokens}
        let projects = cache.projects.overview(from:lower,to:upper)
        report.projects = projects.projects.sorted{$0.tokens>$1.tokens};report.sessions = projects.sessions
        return report
    }
    static func sample()->TokenHistoryCache {
        var c = TokenHistoryCache();let cal = Calendar.current;let today = cal.startOfDay(for:.now)
        for n in 0..<30 {
            let date = cal.date(byAdding:.day,value:-n,to:today)!
            c.archive.days[UsageArchive.dayKey(date)] = [
                CostSource.claudeCode.rawValue:["claude-opus-5-5":ArchiveEntry(input:120_000*(n%4+1),output:41_000*(n%3+1),cacheRead:1_900_000*(n%5+1),cacheWrite:80_000)],
                CostSource.codexCLI.rawValue:["gpt-6.1-sol":ArchiveEntry(input:90_000*(n%5+1),output:54_000*(n%4+1),cacheRead:1_200_000*(n%3+1))]
            ]
        }
        for (day,sources) in c.archive.days {
            for (source,models) in sources {
                let total = models.values.reduce(0){$0+$1.allTokens};var hours = Array(repeating:0,count:24)
                for hour in [9,11,14] {hours[hour] = total/4};hours[20] = total-3*(total/4)
                c.projects.days[day,default:[:]]["sample:teum",default:[:]][source] = ["cli":ProjectDay(hours:hours,models:models)]
            }
        }
        c.archive.lastScan = .now;c.archive.fullScanDone = true
        return c
    }
}
