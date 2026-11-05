import Foundation

@MainActor enum DistributionChecks {
    static func run()->[(String,Bool)] {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("Teum-distribution-"+UUID().uuidString)
        try! FileManager.default.createDirectory(at:home,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:home)}
        var results:[(String,Bool)] = []
        let defaults = Preferences()
        results.append(("새 설치는 노치 켬·숫자+막대",defaults.notchEnabled && defaults.notchStyle == "mixed"))
        func decode(_ value:[String:Any])->Preferences {Preferences.read(try! JSONSerialization.data(withJSONObject:value))!}
        let migrated = decode(["notchEnabled":false,"notchStyle":"bars","leftPadding":27])
        results.append(("이전 기본 조합만 보정하며 다른 설정 보존",migrated.notchEnabled && migrated.notchStyle == "mixed" && migrated.leftPadding == 27))
        let off = decode(["notchDefaultsVersion":1,"notchEnabled":false,"notchStyle":"bars"])
        results.append(("새 버전에서 직접 끈 노치는 재실행해도 유지",!off.notchEnabled && off.notchStyle == "bars"))
        let custom = decode(["notchEnabled":false,"notchStyle":"fourNumbers"])
        results.append(("기존 사용자 지정 표시 방식과 끄기 보존",!custom.notchEnabled && custom.notchStyle == "fourNumbers"))
        let enabled = decode(["notchEnabled":true,"notchStyle":"bars"])
        results.append(("이전에 켜둔 막대 모드는 보존",enabled.notchEnabled && enabled.notchStyle == "bars"))
        let missing = decode(["leftPadding":31])
        results.append(("노치 필드 없는 기존 파일도 새 기본값 사용",missing.notchEnabled && missing.notchStyle == "mixed" && missing.leftPadding == 31))
        var chosen = migrated;chosen.notchEnabled = false
        let reopened = Preferences.read(try! JSONEncoder().encode(chosen))!
        results.append(("보정 후 사용자 선택은 다시 보정하지 않음",!reopened.notchEnabled && reopened.notchDefaultsVersion == 1))
        let initial = CodexProfiles.initial(home:home)
        results.append(("빈 사용자 홈에는 기본 코덱스 자리만 생성",initial.streams.filter{$0.source == "codex"}.map(\.id) == ["codex"]))
        let profile = home.appendingPathComponent(".codex-work")
        try! FileManager.default.createDirectory(at:profile,withIntermediateDirectories:true)
        try! Data("{}".utf8).write(to:profile.appendingPathComponent("auth.json"))
        results.append(("다른 사용자 프로필을 감지하며 기본 목록 외 프로필을 복제하지 않음",CodexProfiles.initial(home:home).streams.filter{$0.source == "codex"}.map(\.id) == ["codex-work"]))
        let file = home.appendingPathComponent("session-watches.json")
        let state:[String:Any] = ["schema_version":1,"extra":"keep","rules":[
            ["id":"target","state":"armed","expires_at":2000.0,"session":"one","extra":"keep"],
            ["id":"other","state":"armed","expires_at":2000.0,"session":"two"],
            ["id":"delivered","state":"delivered","expires_at":900.0,"finished_at":950.0]
        ]]
        try! JSONSerialization.data(withJSONObject:state).write(to:file)
        results.append(("체크아웃·Python 없이 알림 취소",SessionWatchStore.cancel("target",directory:home,now:Date(timeIntervalSince1970:1000))))
        let saved = try! JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]
        let rules = saved["rules"] as! [[String:Any]]
        results.append(("취소는 지정한 세션에만 반영",rules[0]["state"] as? String == "cancelled" && rules[1]["state"] as? String == "armed"))
        results.append(("CLI 호환 메타데이터와 알 수 없는 필드 보존",saved["extra"] as? String == "keep" && rules[0]["extra"] as? String == "keep" && rules[0]["finished_at"] as? Double == 1000))
        let before = try! Data(contentsOf:file)
        results.append(("전달 완료 상태를 취소로 덮어쓰지 않음",SessionWatchStore.cancel("delivered",directory:home) && (try? Data(contentsOf:file)) == before))
        results.append(("없는 알림을 요청해도 기존 데이터 보존",!SessionWatchStore.cancel("missing",directory:home) && (try? Data(contentsOf:file)) == before))
        try! Data("broken".utf8).write(to:file)
        results.append(("손상된 파일은 초기화하거나 덮어쓰지 않음",!SessionWatchStore.cancel("target",directory:home) && (try? Data(contentsOf:file)) == Data("broken".utf8)))
        let fixture = QuotaStore.fixture()
        let summary = MenuBarUsage(store:fixture)
        results.append(("메뉴 막대 아이콘은 템플릿 20pt·첫 표시 계정 요약",summary.image.isTemplate && summary.image.size == NSSize(width:20,height:20) && summary.help.contains(fixture.prefs.streams[0].name)))
        results.append(("메뉴 패널 모션 커브 경계 및 단조 증가",MenuPanelAnimator.eased(0) == 0 && MenuPanelAnimator.eased(1) == 1 && MenuPanelAnimator.eased(0.5) > 0.5))
        return results
    }
}
