import Foundation
import QuotaModel

@MainActor enum UsagePolicyChecks {
    static func run()->[String:Bool] {
        var checks:[String:Bool] = [:]
        let now = Calendar.current.startOfDay(for:.now).addingTimeInterval(12*3600)
        let reset = now.addingTimeInterval(3*86400)
        var prefs = Preferences();prefs.streams = [Stream.defaults[1]];prefs.planReserve = 10
        let id = prefs.streams[0].id
        let reading = Reading(snapshot:UsageSnapshot(windows:[UsageWindow(title:"Weekly window",usedPercent:20,resetsAt:reset,windowSeconds:604800)],fetchedAt:now))
        let readings = [id:reading]
        let balanced = QuotaPlanner.build(prefs:prefs,readings:readings,now:now)
        checks["균등 배분 기존 보호량"] = balanced.accounts.first?.spendable == 70
        prefs.usagePolicies[id] = UsagePolicy(mode:.today,deadlineAt:now.addingTimeInterval(12*3600).timeIntervalSince1970,spendReserve:true)
        let today = QuotaPlanner.build(prefs:prefs,readings:readings,now:now)
        checks["오늘 소진은 현재 잔여 전량"] = abs((today.allocations(day:today.days[0]).first?.points ?? 0)-80)<0.001
        checks["소진 뒤 실제 리셋 전에는 배분 없음"] = today.allocations(day:today.days[1]).isEmpty
        checks["오늘 목표는 관측 사용을 더함"] = today.accounts.first?.automaticTarget(now:now,used:30) == 110
        prefs.usagePolicies[id]?.mode = .deadline;prefs.usagePolicies[id]?.deadlineAt = now.addingTimeInterval(86400).timeIntervalSince1970
        let due = QuotaPlanner.build(prefs:prefs,readings:readings,now:now)
        checks["지정일까지 비례 배분"] = abs((due.allocations(day:due.days[0]).first?.points ?? 0)-40)<0.001
        prefs.usagePolicies[id]?.expectedResetAt = now.addingTimeInterval(6*3600).timeIntervalSince1970
        let expected = QuotaPlanner.build(prefs:prefs,readings:readings,now:now)
        checks["예상 리셋은 계획에만 반영"] = expected.accounts.first?.expectedReset == true && expected.accounts.first?.reset != reset && readings[id]?.windows.first?.resetsAt == reset
        prefs.usagePolicies[id]?.deadlineAt = now.addingTimeInterval(-1).timeIntervalSince1970;prefs.usagePolicies[id]?.expectedResetAt = now.addingTimeInterval(-1).timeIntervalSince1970
        let expired = QuotaPlanner.build(prefs:prefs,readings:readings,now:now)
        checks["지난 기한과 예상 리셋 무효화"] = expired.accounts.first?.spendingDeadline == nil && expired.accounts.first?.expectedReset == false
        var ledger = GoalLedger();let day = DailyGoalsStore.key(now)
        ledger.observe(id:id,window:"weekly",remaining:80,at:now,day:day,resetAt:100)
        ledger.observe(id:id,window:"weekly",remaining:70,at:now.addingTimeInterval(1),day:day,resetAt:100)
        ledger.observe(id:id,window:"weekly",remaining:30,at:now.addingTimeInterval(2),day:day,resetAt:200)
        checks["리셋 사이 차이를 사용으로 오집계 안 함"] = ledger.days[day]?.used[id] == 10
        let store = QuotaStore.fixture();let history = store.tokenHistory
        let start = history.reportBuilds
        for _ in 0..<1000 {_ = history.report(now:now)}
        checks["호버 1000번 집계 1회"] = history.reportBuilds-start == 1
        history.period = .all;_ = history.report(now:now)
        checks["기간 변경시 집계 갱신"] = history.reportBuilds-start == 2
        history.cache.archive.lastScan = .now;_ = history.report(now:now)
        checks["캐시 변경시 집계 갱신"] = history.reportBuilds-start == 3
        let encoded = try! JSONEncoder().encode(prefs)
        checks["사용 방식 설정 저장 호환"] = Preferences.read(encoded)?.usagePolicies == prefs.usagePolicies
        return checks
    }
}
