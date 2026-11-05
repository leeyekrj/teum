import Foundation
import Combine
import QuotaModel

struct DailyGoalDay:Codable,Equatable {
    var targets:[String:Double] = [:]
    var used:[String:Double] = [:]
    var overrides:[String:Double]?
    var resetAnchors:[String:Double]?
    var startedAt:Date
}
struct GoalObservation:Codable,Equatable {
    var window:String
    var remaining:Double
    var at:Date
    var resetAt:Double?
}
struct GoalLedger:Codable,Equatable {
    var days:[String:DailyGoalDay] = [:]
    var observations:[String:GoalObservation] = [:]
    mutating func observe(id:String,window:String,remaining:Double,at:Date,day:String,resetAt:Double? = nil) {
        guard remaining.isFinite,(0...100).contains(remaining) else{return}
        if let prior = observations[id],at<=prior.at {return}
        var entry = days[day] ?? DailyGoalDay(startedAt:at)
        if let prior = observations[id],prior.window == window,Calendar.current.isDate(prior.at,inSameDayAs:at),
           prior.resetAt == nil || resetAt == nil || abs(prior.resetAt!-resetAt!)<60 {
            // Count observed decreases, including a new decrease after a grant
            // or reset. Increases never subtract already observed spending.
            entry.used[id,default:0] += max(0,prior.remaining-remaining)
        }
        days[day] = entry;observations[id] = GoalObservation(window:window,remaining:remaining,at:at,resetAt:resetAt)
    }
}

@MainActor final class DailyGoalsStore:ObservableObject {
    @Published var ledger = GoalLedger()
    @Published var error:String?
    private let file:URL
    private let ephemeral:Bool
    init(directory:URL,ephemeral:Bool = false) {
        self.ephemeral = ephemeral;file = directory.appendingPathComponent("daily-goals.json")
        let decoder = JSONDecoder();decoder.dateDecodingStrategy = .secondsSince1970
        if !ephemeral,let data = try? Data(contentsOf:file),let saved = try? decoder.decode(GoalLedger.self,from:data) {ledger = saved}
    }
    var today:DailyGoalDay? {ledger.days[Self.key(.now)]}
    var remaining:[String:Double] {
        guard let today else{return [:]}
        return today.targets.mapValues{$0}.reduce(into:[:]){out,pair in out[pair.key] = max(0,pair.value-(today.used[pair.key] ?? 0))}
    }
    static func key(_ date:Date)->String {
        let c = Calendar.current.dateComponents([.year,.month,.day],from:date)
        return String(format:"%04d-%02d-%02d",c.year!,c.month!,c.day!)
    }
    func observe(prefs:Preferences,readings:[String:Reading],now:Date = .now) {
        let previous = ledger
        let plan = QuotaPlanner.build(prefs:prefs,readings:readings,now:now)
        let key = Self.key(now)
        var day = ledger.days[key] ?? DailyGoalDay(startedAt:now)
        ledger.days[key] = day
        for s in prefs.streams where s.connected != false {
            guard let r = readings[s.id],!r.stale(now:now,minutes:prefs.refreshMinutes),let snapshot = r.snapshot,Calendar.current.isDate(snapshot.fetchedAt,inSameDayAs:now),
                  let w = WindowLogic.primary(r.windows).filter({QuotaPlanner.weekly($0)}).min(by:{(WindowLogic.remaining($0) ?? 101)<(WindowLogic.remaining($1) ?? 101)}),
                  !WindowLogic.expired(w,snapshot:snapshot),let left = WindowLogic.remaining(w) else{continue}
            ledger.observe(id:s.id,window:w.id,remaining:left,at:snapshot.fetchedAt,day:key,resetAt:w.resetsAt?.timeIntervalSince1970)
        }
        day = ledger.days[key] ?? day
        var anchors = day.resetAnchors ?? [:]
        for a in plan.accounts {
            let actualReset = a.window?.resetsAt?.timeIntervalSince1970
            let resetChanged = actualReset.map{value in anchors[a.id].map{abs($0-value)>60} ?? false} ?? false
            if let override = day.overrides?[a.id] {day.targets[a.id] = override}
            else if let custom = prefs.dailyGoalTargets[a.id],custom.isFinite {day.targets[a.id] = max(0,min(1000,custom))}
            else if day.targets[a.id] == nil || resetChanged || a.spendingDeadline != nil {
                day.targets[a.id] = a.automaticTarget(now:now,used:day.used[a.id] ?? 0)
            }
            if let actualReset {anchors[a.id] = actualReset}
        }
        day.resetAnchors = anchors;ledger.days[key] = day
        let keep = Calendar.current.date(byAdding:.day,value:-90,to:now) ?? now
        ledger.days = ledger.days.filter{$0.key>=Self.key(keep)}
        if ledger != previous {save()}
    }
    func target(_ id:String,value:Double) {
        guard value.isFinite else{return}
        let key = Self.key(.now);var day = ledger.days[key] ?? DailyGoalDay(startedAt:.now)
        day.targets[id] = max(0,min(1000,value));var overrides = day.overrides ?? [:];overrides[id] = day.targets[id];day.overrides = overrides;ledger.days[key] = day;save()
    }
    func automatic(prefs:Preferences,readings:[String:Reading]) {
        let plan = QuotaPlanner.build(prefs:prefs,readings:readings)
        let key = Self.key(.now);var day = ledger.days[key] ?? DailyGoalDay(startedAt:.now)
        day.overrides = nil
        for a in plan.accounts {day.targets[a.id] = prefs.dailyGoalTargets[a.id] ?? a.automaticTarget(now:plan.now,used:day.used[a.id] ?? 0)}
        ledger.days[key] = day;save()
    }
    func recalculate(_ id:String,prefs:Preferences,readings:[String:Reading]) {
        let key = Self.key(.now);var day = ledger.days[key] ?? DailyGoalDay(startedAt:.now)
        day.overrides?.removeValue(forKey:id)
        if let a = QuotaPlanner.build(prefs:prefs,readings:readings).accounts.first(where:{$0.id == id}) {
            day.targets[id] = prefs.dailyGoalTargets[id] ?? a.automaticTarget(now:.now,used:day.used[id] ?? 0)
        }
        ledger.days[key] = day;save()
    }
    private func save() {
        guard !ephemeral else{return}
        do {
            try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
            let encoder = JSONEncoder();encoder.dateEncodingStrategy = .secondsSince1970
            try encoder.encode(ledger).write(to:file,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path);error = nil
        } catch {self.error = "오늘 목표 기록을 저장하지 못했어요."}
    }
}
