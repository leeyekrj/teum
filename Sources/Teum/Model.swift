import Foundation
import SwiftUI
import QuotaModel
import QuotaCore

struct Stream: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var source: String
    var profile: String = ""
    var scope: String = ""
    var visible = true
    var warns = true
    var pinned = true
    var ignoredWindows: [String] = []
    var colorHex:String? = nil
    var notifyReset:Bool? = nil
    var notifyLow:Bool? = nil
    var notchWindow:String? = nil
    var hoverPrimary:String? = nil
    var hoverSecondary:String? = nil
    var hoverVisible:Bool? = nil
    var connected:Bool? = nil
    var tint: Color {
        if let colorHex,let custom = Stream.color(colorHex) {return custom}
        return switch source { case "claude": Color(red:0.88,green:0.57,blue:0.42)
        case "codex": profile.isEmpty ? Color(red:0.49,green:0.80,blue:0.71) : (profile.unicodeScalars.reduce(0){$0+Int($1.value)} % 2 == 0 ? Color(red:0.48,green:0.76,blue:0.91) : Color(red:0.39,green:0.79,blue:0.79))
        case "agy": scope == "claude" ? Color(red:0.74,green:0.64,blue:0.96) : Color(red:0.48,green:0.70,blue:0.96)
        case "grok": Color(red:0.89,green:0.92,blue:0.96)
        default: Color(red:0.83,green:0.69,blue:0.94) }
    }
    static func color(_ hex:String)->Color? {
        let clean = hex.trimmingCharacters(in:CharacterSet(charactersIn:"#"))
        guard clean.count == 6,let rgb = UInt32(clean,radix:16) else{return nil}
        return Color(red:Double((rgb>>16)&255)/255,green:Double((rgb>>8)&255)/255,blue:Double(rgb&255)/255)
    }
    var symbol: String { switch source {case "claude": "sun.max"; case "codex": "hexagon"; case "agy": "sparkle"; case "grok": "xmark"; default: "k.square"} }
    var origin: String {
        switch source {
        case "claude": "Claude Code"
        case "codex": profile.isEmpty ? "개인 계정" : profile+" 프로필"
        case "agy": scope == "claude" ? "Claude · GPT" : "Gemini"
        case "grok": "Grok · Grok Bot"
        default: "월간 크레딧"
        }
    }
    static let defaults: [Stream] = [
        .init(id:"claude",name:"클로드",source:"claude"),
        .init(id:"codex",name:"코덱스",source:"codex"),
        .init(id:"agy-claude",name:"AGY 클로드",source:"agy",scope:"claude"),
        .init(id:"agy-general",name:"AGY 일반",source:"agy",scope:"gemini"),
        .init(id:"kiro",name:"키로",source:"kiro"),
        .init(id:"grok",name:"그록",source:"grok")
    ]
}

struct Preferences: Codable, Equatable {
    var streams = Stream.defaults
    var notchEnabled = true
    var notchStyle = "mixed"
    var notchDefaultsVersion = 1
    var fitNotch = true
    var leftPadding:Double = 14
    var rightPadding:Double = 14
    var wingWidth: Double = 66
    var cameraWidth: Double = 184
    var cameraPadding: Double = 6
    var panelWidth: Double = 604
    var compact = false
    var showResets = true
    var resetStyle = "relative"
    var resetTodayTomorrow = true
    var resetWeekdays = true
    var showAccount = false
    var showPlan = false
    var showOrigin = true
    var showWindowNames = true
    var showFooter = true
    var showConsumption = true
    var showPaceGuide = true
    /// Run-out forecast beside the reset time when a window would empty first.
    var showRunOut = true
    var singleColumn = false
    var showAllWindows = false
    var threshold: Double = 15
    var refreshMinutes: Double = 5
    var hoverDelay: Double = 0.18
    var closeDelay: Double = 0.4
    var notifications = false
    var islandNotices = true
    var resetNotices = true
    var lowNotices = true
    var paceNotices = false
    var goalNearNotices = false
    var goalReachedNotices = false
    var goalRemainingThreshold:Double = 20
    var noticeSeconds:Double = 4
    var showExcluded = true
    var planReserve:Double = 10
    var planHorizon = "rolling"
    var planScope = "coding"
    var planExcluded:[String] = []
    var planPriority:[String] = []
    /// "percent": rank by each account's own %p. "work": by estimated weighted tokens where measured.
    var planBasis = "percent"
    var dailyGoalTargets:[String:Double] = [:]
    var usagePolicies:[String:UsagePolicy] = [:]
    var launchAtLogin = false
    static func read(_ data:Data) -> Preferences? {
        guard var defaults = (try? JSONSerialization.jsonObject(with:JSONEncoder().encode(Preferences()))) as? [String:Any],let existing = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else{return nil}
        defaults.merge(existing){_,old in old}
        guard let merged = try? JSONSerialization.data(withJSONObject:defaults) else{return nil}
        guard var result = try? JSONDecoder().decode(Preferences.self,from:merged) else{return nil}
        // The original first-run defaults hid the notch entirely. Upgrade that
        // exact legacy combination once; versioned choices and custom styles stay intact.
        if (existing["notchDefaultsVersion"] as? Int ?? 0) < 1,
           existing["notchEnabled"] as? Bool == false,
           (existing["notchStyle"] as? String ?? "bars") == "bars" {
            result.notchEnabled = true
            result.notchStyle = "mixed"
        }
        result.notchDefaultsVersion = 1
        if !result.streams.contains(where:{$0.id == "grok"}),let grok = Stream.defaults.last {result.streams.append(grok)}
        return result
    }
}

enum NotchLayout {
    static func wings(_ prefs:Preferences,count:Int)->(left:CGFloat,right:CGFloat) {
        let half = (count+1)/2
        func left(_ n:CGFloat)->CGFloat {let w = n+prefs.leftPadding*2;return prefs.fitNotch ? w : max(w,prefs.wingWidth)}
        func right(_ n:CGFloat)->CGFloat {let w = n+prefs.rightPadding*2;return prefs.fitNotch ? w : max(w,prefs.wingWidth)}
        let numberCount = min(2,count)
        let graphCount = max(0,count-numberCount)
        switch prefs.notchStyle {
        case "fourNumbers":
            let n = min(4,count);let l = (n+1)/2;let r = n-l
            return (left(max(0,CGFloat(l)*36-6)),right(max(0,CGFloat(r)*36-6)))
        case "compactNumbers":return(left(30),right(30))
        case "mixed":return(left(max(0,CGFloat(numberCount)*32-4)),right(max(0,CGFloat(graphCount)*9-4)))
        case "allNumbers":return(left(max(0,CGFloat(half)*32-4)),right(max(0,CGFloat(count-half)*32-4)))
        case "numbers":return(left(30),right(max(0,CGFloat(count)*9-4)))
        default:return(left(max(0,CGFloat(half)*9-4)),right(max(0,CGFloat(count-half)*9-4)))
        }
    }
    static func wing(_ prefs:Preferences,count:Int) -> CGFloat {
        let w = wings(prefs,count:count);return max(w.left,w.right)
    }
    static func cameraGap(_ prefs:Preferences,detected:CGFloat) -> CGFloat {
        max(detected,prefs.cameraWidth)+prefs.cameraPadding*2
    }
}

struct Sample: Codable {
    var time: Date
    var remaining: Double
    var windowID: String
    var reset: Date?
}

struct Reading {
    var snapshot: UsageSnapshot?
    var error: String?
    var loading = false
    var windows: [UsageWindow] { snapshot?.windows ?? [] }
    func stale(now: Date = .now, minutes: Double = 5) -> Bool {
        guard let snapshot else { return true }
        return error != nil || now.timeIntervalSince(snapshot.fetchedAt) > max(minutes * 120, 600)
    }
}

enum WindowLogic {
    static func remaining(_ window: UsageWindow) -> Double? {
        guard let p = window.usedPercent, p.isFinite else { return nil }
        return min(100, max(0, 100 - p))
    }
    static func primary(_ windows: [UsageWindow]) -> [UsageWindow] {
        windows.filter { !$0.extra && $0.credit == nil && $0.usedPercent != nil }
    }
    static func short(_ w: UsageWindow) -> Bool {
        if let seconds = w.windowSeconds { return seconds < 86_400 }
        return w.title.lowercased().contains("5-hour") || w.title.lowercased().contains("session")
    }
    static func headline(_ windows: [UsageWindow]) -> UsageWindow? {
        let values = primary(windows)
        return values.max { ($0.usedPercent ?? 0) < ($1.usedPercent ?? 0) }
    }
    static func horizon(_ windows: [UsageWindow], short: Bool) -> UsageWindow? {
        primary(windows).filter { Self.short($0) == short }.max { ($0.usedPercent ?? 0) < ($1.usedPercent ?? 0) }
    }
    static func selected(_ windows:[UsageWindow],choice:String?,fallback:String = "auto")->UsageWindow? {
        let key = choice ?? fallback
        if key == "none" {return nil}
        if key.hasPrefix("id:") {return windows.first{$0.id == String(key.dropFirst(3)) && remaining($0) != nil}}
        if key == "short" {return horizon(windows,short:true)}
        if key == "long" {return horizon(windows,short:false)}
        if key == "week" {return headline(primary(windows).filter{($0.windowSeconds.map{abs($0-604800)<86400} ?? false) || $0.title.lowercased().contains("week")})}
        if key == "month" {return headline(primary(windows).filter{($0.windowSeconds ?? 0)>=2419200 || $0.title.lowercased().contains("month")})}
        return headline(windows)
    }
    static func label(_ w: UsageWindow) -> String {
        if let s = w.windowSeconds { return s < 3600 ? "\(max(1,s/60))분" : (s < 86_400 ? "\(s/3600)시간" : (s == 604_800 ? "주간" : "\(s/86_400)일")) }
        if w.title.lowercased().contains("month") { return "월간" }
        return w.label ?? w.scope ?? w.title
    }
    static func resetText(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "리셋 시각 없음" }
        let diff = date.timeIntervalSince(now)
        guard diff > 0 else { return "리셋 경과 · 확인 필요" }
        let minutes = max(1, Int(ceil(diff / 60)))
        if minutes < 60 { return "\(minutes)분 후" }
        if minutes < 1440 { return "\(minutes/60)시간 \(minutes%60)분 후" }
        return "\(minutes/1440)일 \((minutes%1440)/60)시간 후"
    }
    static func resetDisplay(_ date:Date?,style:String,todayTomorrow:Bool = true,weekdays:Bool = true,now:Date = .now,calendar:Calendar = .current)->String {
        guard style != "relative" else{return resetText(date,now:now)}
        guard let date else{return "리셋 시각 없음"}
        let time = DateFormats.formatter("HH:mm",calendar:calendar).string(from:date)
        if style == "calendar" {
            if todayTomorrow {
                if calendar.isDate(date,inSameDayAs:now) {return "오늘 "+time}
                if let tomorrow = calendar.date(byAdding:.day,value:1,to:now),calendar.isDate(date,inSameDayAs:tomorrow) {return "내일 "+time}
            }
            if weekdays {
                let day = DateFormats.formatter("EEEE",calendar:calendar).string(from:date)
                if let week = calendar.dateInterval(of:.weekOfYear,for:now),date >= week.start,date < week.end {return "이번 주 "+day+" "+time}
                if let next = calendar.date(byAdding:.weekOfYear,value:1,to:now),let week = calendar.dateInterval(of:.weekOfYear,for:next),date >= week.start,date < week.end {return "다음 주 "+day+" "+time}
            }
        }
        return DateFormats.formatter("M월 d일 HH:mm",calendar:calendar).string(from:date)
    }
    static func expired(_ window: UsageWindow, snapshot: UsageSnapshot?) -> Bool {
        guard let reset = window.resetsAt, let fetched = snapshot?.fetchedAt else { return false }
        return reset <= .now && fetched < reset
    }
    static func nextResetCheck(_ snapshots:[UsageSnapshot],now:Date = .now)->Date? {
        snapshots.flatMap {snapshot in snapshot.windows.compactMap {window -> Date? in
            guard let reset = window.resetsAt else{return nil}
            if reset>now {return reset.addingTimeInterval(1)}
            // A just-passed boundary whose fetch failed is retried briefly;
            // this is bounded so an old/offline snapshot cannot busy-poll.
            if now.timeIntervalSince(reset)<90 {return now.addingTimeInterval(10)}
            return nil
        }}.min()
    }
    static func exact(_ date: Date?) -> String {
        guard let date else { return "제공되지 않음" }
        return DateFormats.formatter("M월 d일 (E) HH:mm:ss").string(from:date)
    }
}

@MainActor final class QuotaStore: ObservableObject {
    @Published var prefs: Preferences
    /// Kept apart from the store's published state; see PanelNavigation.
    let navigation = PanelNavigation()
    var panelPage:Int {
        get {navigation.page}
        set {navigation.go(to:newValue,animated:false)}
    }
    var panelInteractions = 0
    lazy var tokenHistory = TokenHistoryStore(directory:directory,fixture:ephemeral,deferred:!ephemeral)
    lazy var dailyGoals = DailyGoalsStore(directory:directory,ephemeral:ephemeral)
    var currentPlan:QuotaPlan {QuotaPlanner.build(prefs:prefs,readings:readings,dailyRemaining:dailyGoals.remaining,capacity:capacity.estimates.compactMapValues(\.tokensPerPoint))}
    /// Estimated size of 1%p per account, and the weekly samples behind it.
    @Published var capacity = CapacityBook()
    private var capacityTask:Task<Void,Never>?
    @Published var readings: [String: Reading] = [:]
    @Published var refreshing = false
    @Published var lastRefresh: Date?
    @Published var saveError: String?
    @Published var history: [String: [Sample]] = [:]
    let directory: URL
    let ephemeral: Bool
    private var cache: [String: UsageSnapshot] = [:]
    private var timer: Timer?
    private var resetTimer:Timer?
    var didRefresh: (() -> Void)?
    var previewNotice: ((IslandNotice)->Void)?
    var visible: [Stream] { prefs.streams.filter { $0.visible && $0.hoverVisible != false && (prefs.showExcluded || $0.warns) } }
    var panelHeight:CGFloat {
        let rows = prefs.showAllWindows ? visible.reduce(0) { $0 + 43 + max(1,readings[$1.id]?.windows.count ?? 0)*38 } : visible.count*(prefs.compact ? 48 : 58)
        return min(680,max(320,CGFloat(134+rows)-(prefs.showFooter ? 0 : 16)))
    }
    var pinned: [Stream] { prefs.streams.filter { $0.visible && $0.pinned && $0.connected != false } }
    var notchNumberCount:Int {
        switch prefs.notchStyle {
        case "fourNumbers":return min(4,pinned.count)
        case "mixed","compactNumbers":return min(2,pinned.count)
        case "allNumbers":return pinned.count
        case "numbers":return min(1,pinned.count)
        default:return 0
        }
    }
    var numberStreams: [Stream] {Array(pinned.prefix(notchNumberCount))}
    func notchWindow(_ stream:Stream)->UsageWindow? {WindowLogic.selected(readings[stream.id]?.windows ?? [],choice:stream.notchWindow)}
    func warns(_ stream:Stream,window:UsageWindow)->Bool {
        guard stream.warns,!stream.ignoredWindows.contains(window.id),let r = readings[stream.id],!r.stale(minutes:prefs.refreshMinutes),!WindowLogic.expired(window,snapshot:r.snapshot) else{return false}
        return (WindowLogic.remaining(window) ?? 101)<=prefs.threshold
    }
    var warningStreams: [Stream] {
        prefs.streams.filter { stream in
            guard stream.visible && stream.warns, let r = readings[stream.id], !r.stale(minutes:prefs.refreshMinutes) else { return false }
            return WindowLogic.primary(r.windows).contains { w in
                !stream.ignoredWindows.contains(w.id) && !WindowLogic.expired(w,snapshot:r.snapshot) && (WindowLogic.remaining(w) ?? 101) <= prefs.threshold
            }
        }
    }
    init(directory: URL? = nil, ephemeral: Bool = false,bootstrapLegacy: Bool = true) {
        self.ephemeral = ephemeral
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Teum")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        self.prefs = (try? Data(contentsOf:self.directory.appendingPathComponent("settings.json"))).flatMap(Preferences.read) ?? CodexProfiles.initial()
        if !ephemeral {
            let existing = Set(prefs.streams.map(\.id))
            prefs.streams += CodexProfiles.discover().filter{!existing.contains($0.id)}
        }
        cache = (try? decoder.decode([String:UsageSnapshot].self,from:Data(contentsOf:self.directory.appendingPathComponent("readings.json")))) ?? [:]
        history = (try? decoder.decode([String:[Sample]].self,from:Data(contentsOf:self.directory.appendingPathComponent("history.json")))) ?? [:]
        // Read-only bootstrap from existing readings; never write QuotaBar's files.
        if cache.isEmpty && !ephemeral && bootstrapLegacy {
            struct OldCache: Decodable { let snapshots: [String:UsageSnapshot] }
            let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/QuotaBar/snapshots.json")
            if let old = try? decoder.decode(OldCache.self,from:Data(contentsOf:file)) {
                for stream in prefs.streams where stream.profile.isEmpty {
                    if var snapshot = old.snapshots[stream.source == "agy" ? "antigravity" : stream.source] {
                        snapshot.windows = Self.filtered(snapshot.windows,for:stream)
                        cache[stream.id] = snapshot
                    }
                }
            }
        }
        if !ephemeral {
            let capacityDecoder = JSONDecoder();capacityDecoder.dateDecodingStrategy = .secondsSince1970
            capacity = (try? capacityDecoder.decode(CapacityBook.self,from:Data(contentsOf:self.directory.appendingPathComponent("plan-capacity.json")))) ?? CapacityBook()
            if capacity.samples.isEmpty {
                // Start from the day of samples Teum already keeps.
                for (id,list) in history {for s in list where s.windowID.lowercased().contains("week") {capacity.record(id:id,used:100-s.remaining,reset:s.reset,at:s.time)}}
            }
        }
        for (id,snapshot) in cache { readings[id] = Reading(snapshot:snapshot) }
        for stream in prefs.streams where stream.connected == false {readings[stream.id] = Reading(error:"Teum 연결 해제됨");cache.removeValue(forKey:stream.id)}
    }
    static func filtered(_ windows: [UsageWindow],for stream: Stream) -> [UsageWindow] {
        guard stream.source == "agy" else { return windows }
        return windows.filter {
            let s = ($0.scope ?? $0.title).lowercased()
            return stream.scope == "claude" ? (s.contains("claude") || s.contains("gpt")) : s.contains("gemini")
        }
    }
    func save() {
        guard !ephemeral else { return }
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]; encoder.dateEncodingStrategy = .secondsSince1970
            for (name,data) in [("settings.json",try encoder.encode(prefs)),("readings.json",try encoder.encode(cache)),("history.json",try encoder.encode(history))] {
                let file = directory.appendingPathComponent(name)
                try data.write(to:file,options:.atomic)
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
            }
            saveError = nil
        } catch { saveError = "설정을 저장하지 못했어요. 저장 공간과 폴더 권한을 확인해 주세요." }
    }
    func schedule() {
        timer?.invalidate()
        guard !ephemeral else { return }
        timer = Timer.scheduledTimer(withTimeInterval:max(60,prefs.refreshMinutes*60),repeats:true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }; timer?.tolerance = 10
        scheduleResetCheck()
    }
    private func scheduleResetCheck() {
        resetTimer?.invalidate();resetTimer = nil
        guard !ephemeral else{return}
        let snapshots = prefs.streams.filter{$0.connected != false}.compactMap{readings[$0.id]?.snapshot}
        guard let date = WindowLogic.nextResetCheck(snapshots) else{return}
        resetTimer = Timer.scheduledTimer(withTimeInterval:max(0.5,date.timeIntervalSinceNow),repeats:false) {[weak self] _ in
            Task {@MainActor in await self?.refresh()}
        }
        resetTimer?.tolerance = 0.25
    }
    func move(_ id: String,by delta: Int) {
        guard let i = prefs.streams.firstIndex(where:{$0.id == id}) else { return }
        let j = i + delta; guard prefs.streams.indices.contains(j) else { return }
        prefs.streams.swapAt(i,j); save()
    }
    @discardableResult func discoverProfiles()->Int {
        let existing = Set(prefs.streams.map(\.id))
        let found = CodexProfiles.discover().filter{!existing.contains($0.id)}
        prefs.streams += found;save();return found.count
    }
    func setConnected(_ id:String,_ enabled:Bool) {
        guard let target = prefs.streams.first(where:{$0.id == id}) else{return}
        let ids = prefs.streams.filter{target.source == "agy" ? $0.source == "agy" : $0.id == id}.map(\.id)
        for i in prefs.streams.indices where ids.contains(prefs.streams[i].id) {
            let key = prefs.streams[i].id
            prefs.streams[i].connected = enabled
            readings[key] = enabled ? Reading() : Reading(error:"Teum 연결 해제됨")
            cache.removeValue(forKey:key)
        }
        save()
    }
    func refresh() async {
        guard !refreshing && !ephemeral else { return }
        refreshing = true
        let streams = prefs.streams.filter{$0.visible && $0.connected != false}
        for stream in streams { var r = readings[stream.id] ?? Reading(); r.loading = true; readings[stream.id] = r }
        // AGY's two rows share one read, never two CLI launches per cycle.
        var sources: [Stream] = []
        var agyAdded = false
        for s in streams {
            if s.source == "agy" { if agyAdded { continue }; agyAdded = true }
            sources.append(s)
        }
        let dir = directory
        await withTaskGroup(of:(String,UsageSnapshot?,String?).self) { group in
            for stream in sources {
                group.addTask {
                    do { return (stream.id,try await Collector.fetch(stream,directory:dir),nil) }
                    catch { return (stream.id,nil,Collector.message(error,source:stream.source)) }
                }
            }
            for await (id,snapshot,error) in group {
                guard let original = streams.first(where:{$0.id == id}) else { continue }
                let targets = original.source == "agy" ? streams.filter({$0.source == "agy"}) : [original]
                for stream in targets {
                    guard prefs.streams.first(where:{$0.id == stream.id})?.connected != false else{continue}
                    var value = snapshot
                    if var v = value { v.windows = Self.filtered(v.windows,for:stream); value = v }
                    if let value, !value.windows.isEmpty {
                        readings[stream.id] = Reading(snapshot:value)
                        cache[stream.id] = value
                        if let w = WindowLogic.selected(value.windows,choice:stream.notchWindow), let remaining = WindowLogic.remaining(w) {
                            var samples = history[stream.id] ?? []
                            samples.append(Sample(time:value.fetchedAt,remaining:remaining,windowID:w.id,reset:w.resetsAt))
                            history[stream.id] = Array(samples.suffix(288))
                        }
                    } else {
                        var r = readings[stream.id] ?? Reading()
                        r.error = error ?? "이 모델 그룹의 한도를 받지 못했어요. 다음 새로고침에서 다시 확인합니다."
                        r.loading = false; readings[stream.id] = r
                    }
                }
            }
        }
        lastRefresh = .now; refreshing = false;dailyGoals.observe(prefs:prefs,readings:readings);save(); scheduleResetCheck();recordCapacity(); didRefresh?()
    }
    /// The same weekly window the plan uses, sampled when it moves.
    func recordCapacity(now:Date = .now) {
        guard !ephemeral else{return}
        var book = capacity;var changed = false
        for s in prefs.streams where s.connected != false {
            guard let r = readings[s.id],!r.stale(now:now,minutes:prefs.refreshMinutes),let snapshot = r.snapshot,
                  let w = WindowLogic.primary(r.windows).filter({QuotaPlanner.weekly($0)}).min(by:{(WindowLogic.remaining($0) ?? 101)<(WindowLogic.remaining($1) ?? 101)}),
                  !WindowLogic.expired(w,snapshot:snapshot),let left = WindowLogic.remaining(w) else{continue}
            if book.record(id:s.id,used:100-left,reset:w.resetsAt,at:snapshot.fetchedAt) {changed = true}
        }
        if changed {capacity = book;saveCapacity()}
        if capacity.estimatedAt.map({now.timeIntervalSince($0)>6*3600}) ?? true {estimateCapacity()}
    }
    /// Reads local logs on a utility task; never on the main thread.
    func estimateCapacity() {
        guard !ephemeral,capacityTask == nil else{return}
        let streams = prefs.streams.filter{$0.connected != false},samples = capacity.samples
        let tokenFile = directory.appendingPathComponent("token-history.json")
        capacityTask = Task {[weak self] in
            // Claude's hours come from the token history; bring it up to date first.
            if let history = self?.tokenHistory {await history.load(streams:streams)}
            let estimates = await Task.detached(priority:.utility) {()->[String:CapacityEstimate] in
                let decoder = JSONDecoder();decoder.dateDecodingStrategy = .secondsSince1970
                let tokens = (try? Data(contentsOf:tokenFile)).flatMap{try? decoder.decode(TokenHistoryCache.self,from:$0)}
                return CapacityEstimator.estimate(streams:streams,samples:samples,tokenCache:tokens,home:FileManager.default.homeDirectoryForCurrentUser,now:.now)
            }.value
            guard let self else{return}
            self.capacity.estimates = estimates;self.capacity.estimatedAt = .now
            self.saveCapacity();self.capacityTask = nil
        }
    }
    private func saveCapacity() {
        guard !ephemeral else{return}
        let encoder = JSONEncoder();encoder.dateEncodingStrategy = .secondsSince1970;encoder.outputFormatting = [.sortedKeys]
        let file = directory.appendingPathComponent("plan-capacity.json")
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            try encoder.encode(capacity).write(to:file,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        } catch {saveError = "배분 추정치를 저장하지 못했어요."}
    }
    func consumption(_ id: String) -> String? {
        let items = history[id] ?? []
        guard let last = items.last, let first = items.first(where: { last.time.timeIntervalSince($0.time) <= 3600 && last.time.timeIntervalSince($0.time) >= 60 && $0.windowID == last.windowID && $0.reset == last.reset }), first.remaining >= last.remaining else { return nil }
        return "최근 \(max(1,Int(last.time.timeIntervalSince(first.time)/60)))분 · \(String(format:"%.1f",first.remaining-last.remaining))%p 사용"
    }
    static func fixture(_ kind: String = "normal") -> QuotaStore {
        let store = QuotaStore(ephemeral:true)
        store.prefs = Preferences(); store.prefs.notchEnabled = true
        let values: [[Double]] = [[96,16],[73],[82,59],[98,95],[0],[70]]
        for (i,s) in store.prefs.streams.enumerated() {
            let windows = values[i].enumerated().map { j,left in
                UsageWindow(title:values[i].count == 1 ? (s.source == "kiro" ? "Monthly credits" : "Weekly window") : (j == 0 ? "5-hour window" : "Weekly window"),usedPercent:100-left,resetsAt:Date().addingTimeInterval(j == 0 && values[i].count > 1 ? 3600*2.4 : 86400*2.3),windowSeconds:s.source == "kiro" ? nil : (j == 0 && values[i].count > 1 ? 18000 : 604800))
            }
            let snap = UsageSnapshot(planName:s.source == "claude" ? "Max 20x" : s.source == "codex" ? "Pro 100" : nil,account:"demo@example.com",windows:windows)
            store.readings[s.id] = Reading(snapshot:snap)
        }
        store.prefs.streams[4].warns = false
        store.lastRefresh = .now
        if kind == "stale" { store.readings["codex"]?.error = "연결이 끊겼어요. 마지막 확인 값을 표시합니다." }
        if kind == "empty" { store.prefs.streams = [] }
        if kind == "long" { store.prefs.streams[1].name = "코덱스 워크스페이스 긴 이름" }
        return store
    }
    static func showcase() -> QuotaStore {
        let store = QuotaStore(ephemeral:true)
        store.prefs = Preferences(); store.prefs.notchEnabled = true; store.prefs.notchStyle = "mixed"
        let now = Date()
        let spec: [(String,String?,[(String,Double,Double,Int?)])] = [
            ("claude","Max 20x",[("5-hour window",84,3600*3.2,18000),("Weekly window",62,86400*4.25,604800)]),
            ("codex","Pro 100",[("5-hour window",91,3600*4.3,18000),("Weekly window",74,86400*5.1,604800)]),
            ("agy-claude",nil,[("5-hour window",76,3600*2.1,18000),("Weekly window",28,86400*3.6,604800)]),
            ("agy-general",nil,[("5-hour window",95,3600*3.8,18000),("Weekly window",88,86400*4.75,604800)]),
            ("kiro",nil,[("Monthly credits",65,86400*18.4,nil)]),
            ("grok",nil,[("Weekly window",80,86400*3.5,604800)])
        ]
        for (id,plan,items) in spec {
            let windows = items.map { title,left,resetOffset,seconds in
                UsageWindow(title:title,usedPercent:100-left,resetsAt:now.addingTimeInterval(resetOffset),windowSeconds:seconds)
            }
            store.readings[id] = Reading(snapshot:UsageSnapshot(planName:plan,account:"demo@example.com",windows:windows,fetchedAt:now))
        }
        store.lastRefresh = now
        store.dailyGoals.observe(prefs:store.prefs,readings:store.readings,now:now)
        let todayKey = DailyGoalsStore.key(now)
        store.dailyGoals.ledger.days[todayKey]?.used = ["claude":4.8,"codex":3.4,"agy-claude":5.2,"agy-general":4.5]
        return store
    }
}

enum Collector {
    static func fetch(_ stream: Stream,directory: URL) async throws -> UsageSnapshot {
        guard stream.connected != false else{throw FetchError.disconnected}
        if stream.source == "codex" {
            let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(stream.profile.isEmpty ? ".codex" : ".codex-\(stream.profile)")
            guard let auth = CodexAuthFile(try Data(contentsOf:home.appendingPathComponent("auth.json"))) else { throw FetchError.missing }
            // Only the owner CLI refreshes its rotating token. Reading never switches login.
            var snapshot = try await CodexProvider.usage(accessToken:auth.accessToken,accountID:auth.accountID)
            snapshot.account = auth.email ?? snapshot.account
            return snapshot
        }
        if stream.source == "claude" {
            guard let token = LocalCredentials.claudeOAuthToken() else {
                if LocalCredentials.claudeCredentialState() == .needsAuthorization { throw FetchError.keychain }
                throw FetchError.missing
            }
            return try await ClaudeProvider.usage(token:token,plan:LocalCredentials.claudePlanName())
        }
        let config = ConfigStore(fileURL:directory.appendingPathComponent("collector.json"))
        if stream.source == "grok" {
            if GrokNative.enabled(directory:directory) {return try await GrokBot.dashboardUsage()}
            if GrokDashboard.connected(directory:directory) {return try await GrokDashboard.read(directory:directory)}
            var value = try await GrokProvider(allowCredentialRenewal:false,cursorCardIsShown:false).fetch(config:config)
            if value.windows.allSatisfy({$0.extra}) {
                for i in value.windows.indices where value.windows[i].scope == "Grok Bot" {value.windows[i].extra = false}
            }
            return value
        }
        guard stream.source == "agy" || stream.source == "kiro" else{throw FetchError.missing}
        return try await ProviderRegistry.make(stream.source == "agy" ? .antigravity : .kiro).fetch(config:config)
    }
    enum FetchError: Error { case missing,keychain,disconnected }
    static func message(_ error: Error, source: String) -> String {
        if case FetchError.disconnected = error {return "Teum 연결 해제됨"}
        if error is GrokDashboard.Failure {return GrokDashboard.message(error)}
        if case FetchError.keychain = error { return "키체인 접근이 필요해요. 아래 ‘클로드 연결 허용’을 눌러 주세요." }
        if case FetchError.missing = error { return "로그인을 읽지 못했어요. 해당 CLI에서 로그인 상태를 확인해 주세요." }
        if let p = error as? ProviderError {
            switch p {
            case .needsAuthorization: return "Grok Bot의 키체인 연결이 필요해요. ‘Grok Bot 연결 허용’을 눌러 주세요."
            case .unauthorized, .sessionExpired: return source == "grok" ? "Grok Bot 로그인이 만료됐어요. 앱을 열어 로그인한 뒤 다시 확인해 주세요." : "로그인 유효 기간을 확인해 주세요. 해당 CLI를 실행한 뒤 다시 새로고침하면 됩니다."
            case .rateLimited: return "조회가 잠시 제한됐어요. 다음 새로고침에서 다시 확인합니다."
            case .network: return "네트워크에 연결하지 못했어요. 연결이 돌아오면 다시 확인합니다."
            case .http(let code): return "서버 응답 \(code) · 잠시 뒤 다시 확인합니다."
            default: break
            }
        }
        if (error as NSError).domain == NSURLErrorDomain { return "네트워크에 연결하지 못했어요. 연결이 돌아오면 다시 확인합니다." }
        return "사용량을 읽지 못했어요. \(source == "agy" ? "agy -p /usage" : "해당 CLI의 로그인")를 확인한 뒤 다시 시도해 주세요."
    }
}
