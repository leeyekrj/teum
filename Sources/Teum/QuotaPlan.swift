import Foundation
import QuotaModel

struct PlanDay:Identifiable {
    var start:Date
    var end:Date
    var id:Date {start}
}
struct PlanAllowance:Identifiable {
    var stream:Stream
    var remaining:Double
    var reset:Date
    var period:TimeInterval
    var reserve:Double
    var shortBlocked:Bool
    var blockedUntil:Date?
    var shortRemaining:Double?
    var todayRemaining:Double? = nil
    var window:UsageWindow? = nil
    var spendingDeadline:Date? = nil
    var expectedReset = false
    /// Estimated weighted tokens per 1%p of this account's weekly window.
    var tokensPerPoint:Double? = nil
    var id:String {stream.id}
    /// Weighted tokens that 1%p-per-day pressure stands for; nil when unmeasured.
    func workPressure(now:Date)->Double? {tokensPerPoint.map{pressure(now:now)*$0}}
    var spendable:Double {max(0,remaining-reserve)}
    func pressure(now:Date)->Double {spendable/max(1.0/24,(spendingDeadline ?? reset).timeIntervalSince(now)/86400)}
    func automaticTarget(now:Date,used:Double = 0,calendar:Calendar = .current)->Double {
        if let deadline = spendingDeadline {
            let midnight = calendar.date(byAdding:.day,value:1,to:calendar.startOfDay(for:now)) ?? now.addingTimeInterval(86400)
            let fraction = max(0,min(1,min(midnight,deadline).timeIntervalSince(now)/max(1,deadline.timeIntervalSince(now))))
            return used+spendable*fraction
        }
        return used+min(100,min(spendable,pressure(now:now)))
    }
}
struct PlanAllocation:Identifiable {
    var stream:Stream
    var points:Double
    var projected:Bool
    var resets:Bool
    var id:String {stream.id}
}
struct PlanOmission:Identifiable {
    var stream:Stream
    var reason:String
    var id:String {stream.id}
}
struct QuotaPlan {
    var now:Date
    var end:Date
    var reserve:Double
    var days:[PlanDay]
    var accounts:[PlanAllowance]
    var omitted:[PlanOmission]
    var basis = "percent"
    var next:PlanAllowance? {accounts.first{!$0.shortBlocked && $0.spendable>0 && ($0.todayRemaining ?? 1)>0}}
    func allocations(day:PlanDay)->[PlanAllocation] {
        let todayEnd = days.first?.end ?? now
        return accounts.map {a in
            var cursor = now;var boundary = a.reset
            var budget = a.spendable;var points = 0.0;var projected = false
            var committedToday = 0.0
            // A week-long horizon reaches at most two weekly cycles. Bound
            // the loop even if an injected provider period is malformed.
            for cycle in 0..<4 {
                if cursor>=day.end || cursor>=end {break}
                let spendingEnd = cycle == 0 ? min(a.spendingDeadline ?? boundary,boundary) : boundary
                let segmentEnd = min(spendingEnd,end)
                let ready:Date
                if a.shortBlocked,cycle == 0 {ready = max(cursor,a.blockedUntil ?? boundary)} else {ready = cursor}
                if let cap = a.todayRemaining,ready<todayEnd {
                    let todayFinish = min(segmentEnd,todayEnd)
                    let assigned = ready<todayFinish ? min(budget,max(0,cap-committedToday)) : 0
                    committedToday += assigned
                    let overlap = max(0,min(todayFinish,day.end).timeIntervalSince(max(ready,day.start)))
                    if assigned>0,overlap>0,todayFinish>ready {points += assigned*overlap/todayFinish.timeIntervalSince(ready);projected = projected || cycle>0}
                    // Honor today's remaining goal, then distribute only the
                    // unassigned quota across the rest of this reset cycle.
                    let futureStart = max(ready,todayEnd)
                    let start = max(futureStart,day.start),finish = min(segmentEnd,day.end)
                    if finish>start,spendingEnd>futureStart {
                        points += (budget-assigned)*finish.timeIntervalSince(start)/spendingEnd.timeIntervalSince(futureStart)
                        projected = projected || cycle>0
                    }
                } else {
                    let start = max(ready,day.start),finish = min(segmentEnd,day.end)
                    if finish>start,spendingEnd>ready {
                        points += budget*finish.timeIntervalSince(start)/spendingEnd.timeIntervalSince(ready)
                        projected = projected || cycle>0
                    }
                }
                guard boundary<end else{break}
                cursor = boundary;boundary = boundary.addingTimeInterval(a.period);budget = 100-a.reserve
            }
            return PlanAllocation(stream:a.stream,points:max(0,points),projected:projected,resets:a.reset>=day.start && a.reset<day.end)
        }.filter{$0.points>0.0001}.sorted{$0.points>$1.points}
    }
}

enum QuotaPlanner {
    static func weekly(_ window:UsageWindow)->Bool {
        if let seconds = window.windowSeconds {return seconds>=6*86400 && seconds<=8*86400}
        let title = window.title.lowercased()
        return title.contains("week") || title.contains("주간") || title.contains("7-day")
    }
    static func build(prefs:Preferences,readings:[String:Reading],now:Date = .now,calendar:Calendar = .current,dailyRemaining:[String:Double] = [:],capacity:[String:Double] = [:])->QuotaPlan {
        let reserve = max(0,min(50,prefs.planReserve.isFinite ? prefs.planReserve : 10))
        let end:Date
        var weekCalendar = calendar;weekCalendar.firstWeekday = 2
        if prefs.planHorizon == "week",let week = weekCalendar.dateInterval(of:.weekOfYear,for:now) {end = week.end}
        else {end = calendar.date(byAdding:.day,value:7,to:now) ?? now.addingTimeInterval(7*86400)}
        var days:[PlanDay] = [];var cursor = now
        for _ in 0..<8 {
            guard cursor<end else{break}
            let midnight = calendar.date(byAdding:.day,value:1,to:calendar.startOfDay(for:cursor)) ?? cursor.addingTimeInterval(86400)
            let finish = min(midnight,end);days.append(PlanDay(start:cursor,end:finish));cursor = finish
        }
        var accounts:[PlanAllowance] = [];var omitted:[PlanOmission] = []
        for stream in prefs.streams where stream.visible && stream.connected != false {
            func skip(_ reason:String) {omitted.append(PlanOmission(stream:stream,reason:reason))}
            if prefs.planScope != "all",!["claude","codex","agy"].contains(stream.source) {skip("코딩 계정 범위 밖");continue}
            if prefs.planExcluded.contains(stream.id) {skip("계획에서 제외함");continue}
            guard let reading = readings[stream.id],reading.snapshot != nil else {skip("사용량 연결 확인 필요");continue}
            guard !reading.stale(now:now,minutes:prefs.refreshMinutes) else {skip("최신 값 확인 필요");continue}
            let windows = WindowLogic.primary(reading.windows).filter{weekly($0)}
            guard let window = windows.filter({$0.resetsAt.map{$0>now} ?? false}).min(by:{(WindowLogic.remaining($0) ?? 101)<(WindowLogic.remaining($1) ?? 101)}),let left = WindowLogic.remaining(window),let reset = window.resetsAt else {skip(windows.isEmpty ? "주간 한도 없음" : "주간 리셋 시각 확인 필요");continue}
            let shorts = WindowLogic.primary(reading.windows).filter{WindowLogic.short($0)}
            let short = shorts.min{(WindowLogic.remaining($0) ?? 101)<(WindowLogic.remaining($1) ?? 101)}
            let shortLeft = short.flatMap(WindowLogic.remaining)
            var blocked:Date?
            let shortBlocked = shortLeft.map{$0<=5} ?? false
            if let short,let shortLeft,shortLeft<=5 {
                // Weekly and short percentages have different denominators;
                // use the short window only as a readiness guard.
                blocked = short.resetsAt.flatMap{$0>now ? $0 : nil}
            }
            let policy = prefs.usagePolicies[stream.id] ?? UsagePolicy()
            let expected = policy.expectedResetAt.flatMap{$0.isFinite && $0>now.timeIntervalSince1970 ? Date(timeIntervalSince1970:$0) : nil}
            let effectiveReset = expected ?? reset
            accounts.append(PlanAllowance(stream:stream,remaining:left,reset:effectiveReset,period:TimeInterval(window.windowSeconds ?? 604800),reserve:policy.spendReserve ? 0 : reserve,shortBlocked:shortBlocked,blockedUntil:blocked,shortRemaining:shortLeft,todayRemaining:dailyRemaining[stream.id],window:window,spendingDeadline:policy.deadline(now:now,reset:effectiveReset,calendar:calendar),expectedReset:expected != nil,tokensPerPoint:capacity[stream.id].flatMap{$0.isFinite && $0>0 ? $0 : nil}))
        }
        accounts.sort {a,b in
            let ar = a.spendable>0 && !a.shortBlocked && (a.todayRemaining ?? 1)>0,br = b.spendable>0 && !b.shortBlocked && (b.todayRemaining ?? 1)>0
            if ar != br {return ar}
            let ai = prefs.planPriority.firstIndex(of:a.id) ?? Int.max,bi = prefs.planPriority.firstIndex(of:b.id) ?? Int.max
            if ai != bi {return ai<bi}
            if prefs.planBasis == "work" {
                // Measured accounts compare in work; unmeasured ones keep %p order after them.
                let aw = a.workPressure(now:now),bw = b.workPressure(now:now)
                if (aw != nil) != (bw != nil) {return aw != nil}
                if let aw,let bw,abs(aw-bw)>max(aw,bw)*0.0001 {return aw>bw}
            }
            let ap = a.pressure(now:now),bp = b.pressure(now:now)
            if abs(ap-bp)>0.0001 {return ap>bp}
            if a.reset != b.reset {return a.reset<b.reset}
            return (prefs.streams.firstIndex{$0.id == a.id} ?? 0)<(prefs.streams.firstIndex{$0.id == b.id} ?? 0)
        }
        return QuotaPlan(now:now,end:end,reserve:reserve,days:days,accounts:accounts,omitted:omitted,basis:prefs.planBasis == "work" ? "work" : "percent")
    }
    static func json(_ plan:QuotaPlan)->[String:Any] {
        let iso = ISO8601DateFormatter()
        return ["schemaVersion":1,"generatedAt":iso.string(from:plan.now),"until":iso.string(from:plan.end),"reservePercent":plan.reserve,"basis":plan.basis,"method":plan.basis == "work" ? "own-quota-percentage-per-time; ranked by estimated weighted tokens per point where measured (fresh input + 4×output + 0.1×cache read + 1.25×cache write, local logs only); unmeasured accounts follow in percentage order" : "own-quota-percentage-per-time; no token or work-time equivalence","recommendedStream":plan.next?.id as Any? ?? NSNull(),"accounts":plan.accounts.map {a in ["id":a.id,"name":a.stream.name,"remainingPercent":a.remaining,"spendablePercentagePoints":a.spendable,"resetAt":iso.string(from:a.reset),"expectedReset":a.expectedReset,"reportedResetAt":a.window?.resetsAt.map{iso.string(from:$0)} as Any? ?? NSNull(),"spendingDeadline":a.spendingDeadline.map{iso.string(from:$0)} as Any? ?? NSNull(),"reservePercent":a.reserve,"targetPercentagePointsPerDay":a.pressure(now:plan.now),"estimatedWeightedTokensPerPercentagePoint":a.tokensPerPoint as Any? ?? NSNull(),"estimatedWeightedTokensSpendable":a.tokensPerPoint.map{$0*a.spendable} as Any? ?? NSNull(),"shortQuotaBlocked":a.shortBlocked,"blockedUntil":a.blockedUntil.map{iso.string(from:$0)} as Any? ?? NSNull()] as [String:Any]},"days":plan.days.map{day in ["from":iso.string(from:day.start),"until":iso.string(from:day.end),"targets":plan.allocations(day:day).map{["id":$0.id,"percentagePoints":$0.points,"projectedAfterReset":$0.projected,"resetOnThisDay":$0.resets] as [String:Any]}] as [String:Any]},"omitted":plan.omitted.map{["id":$0.id,"reason":$0.reason]}]
    }
}
