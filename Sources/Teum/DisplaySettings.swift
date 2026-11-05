import SwiftUI
import QuotaCore

struct UsageDisplaySettings:View {
    @ObservedObject var store:QuotaStore
    @State private var selectedID:String
    init(store:QuotaStore,initialID:String? = nil) {
        self.store = store;_selectedID = State(initialValue:initialID ?? store.prefs.streams.first?.id ?? "claude")
    }
    var body:some View {
        VStack(alignment:.leading,spacing:25) {
            LazyVGrid(columns:[GridItem(.adaptive(minimum:125))],spacing:8) {
                ForEach(store.prefs.streams) {s in
                    Button {withAnimation(Motion.navigate){selectedID = s.id}} label: {
                        HStack(spacing:7){BrandMark(stream:s,size:15);Text(s.name).font(.system(size:11,weight:.medium)).lineLimit(1);Spacer(minLength:0)}
                            .padding(.horizontal,10).frame(height:35)
                            .background(Color.white.opacity(selectedID == s.id ? 0.10 : 0.025),in:RoundedRectangle(cornerRadius:8))
                    }.buttonStyle(TeumPressStyle()).accessibilityAddTraits(selectedID == s.id ? [.isSelected] : [])
                }
            }
            ForEach($store.prefs.streams) {$stream in
                if stream.id == selectedID {
                    VStack(alignment:.leading,spacing:23) {
                        HStack(spacing:10){BrandMark(stream:stream,size:22);Text(stream.name).font(.system(size:17,weight:.semibold));Spacer()}
                        if stream.source == "grok" {
                            Text(GrokNative.enabled(directory:store.directory) ? "Grok Bot 앱 로그인으로 주간 사용량을 직접 읽습니다. 브라우저를 열지 않습니다. 연결 변경·해제는 ‘연결’ 메뉴에서 관리합니다." : GrokDashboard.connected(directory:store.directory) ? "현재 Aevo에 로그인한 Grok 계정의 공식 대시보드에서 주간 사용량을 읽습니다. 연결 변경·해제는 ‘연결’ 메뉴에서 관리합니다." : "‘연결’ 메뉴에서 Grok Bot 앱으로 사용량을 직접 연결하세요.").font(.system(size:11)).foregroundStyle(Ink.secondary).fixedSize(horizontal:false,vertical:true)
                        }
                        selector("노치 숫자·막대",choice:$stream.notchWindow,fallback:"auto",stream:stream,allowHidden:false)
                        Toggle("호버 목록에 표시",isOn:Binding(get:{stream.hoverVisible != false},set:{stream.hoverVisible = $0})).font(.system(size:12))
                        selector("호버 · 요약 한도",choice:$stream.hoverPrimary,fallback:store.prefs.singleColumn ? "auto" : "short",stream:stream,allowHidden:true)
                        if !store.prefs.singleColumn {selector("호버 · 추가 한도",choice:$stream.hoverSecondary,fallback:"long",stream:stream,allowHidden:true)}
                    }.id(stream.id).transition(.opacity.combined(with:.offset(y:5)))
                }
            }
            Rectangle().fill(Ink.rule).frame(height:1)
            VStack(alignment:.leading,spacing:16) {
                Text("호버에 표시할 정보").font(.system(size:14,weight:.semibold))
                Toggle("모든 한도 펼치기",isOn:$store.prefs.showAllWindows)
                Toggle("요약 한도 하나만 크게 보기",isOn:$store.prefs.singleColumn)
                Toggle("한도 이름 · 모델 구분",isOn:$store.prefs.showWindowNames)
                Toggle("리셋 시간 표시",isOn:$store.prefs.showResets)
                HStack(spacing:7) {
                    ForEach(["relative","absolute","calendar"],id:\.self) {style in
                        Button {withAnimation(Motion.feedback){store.prefs.resetStyle = style}} label: {
                            HStack(spacing:6) {
                                Text(style == "relative" ? "남은 시간" : style == "absolute" ? "정확한 일시" : "오늘·요일")
                                if store.prefs.resetStyle == style {Image(systemName:"checkmark").font(.system(size:9,weight:.semibold))}
                            }.font(.system(size:11)).padding(.horizontal,12).frame(height:31)
                                .background(Color.white.opacity(store.prefs.resetStyle == style ? 0.11 : 0.025),in:RoundedRectangle(cornerRadius:7))
                        }.buttonStyle(TeumPressStyle()).accessibilityAddTraits(store.prefs.resetStyle == style ? [.isSelected] : [])
                    }
                    Text(store.prefs.resetStyle == "absolute" ? "예: 11월 6일 15:21" : store.prefs.resetStyle == "calendar" ? "예: 다음 주 금요일 15:21" : "예: 3일 2시간 후").font(.system(size:10)).foregroundStyle(Ink.secondary)
                    Spacer(minLength:0)
                }.disabled(!store.prefs.showResets)
                if store.prefs.resetStyle == "calendar" {
                    VStack(spacing:13) {
                        Toggle("오늘·내일로 줄여 표시",isOn:$store.prefs.resetTodayTomorrow)
                        Toggle("이번 주·다음 주 요일로 표시",isOn:$store.prefs.resetWeekdays)
                    }.font(.system(size:11)).disabled(!store.prefs.showResets).transition(.opacity.combined(with:.offset(y:4)))
                }
                Toggle("리셋 시간 옆에 소진 예정 시각 표시",isOn:$store.prefs.showRunOut)
                Toggle("계정 이메일",isOn:$store.prefs.showAccount)
                Toggle("요금제",isOn:$store.prefs.showPlan)
                Toggle("서비스 · 프로필 설명",isOn:$store.prefs.showOrigin)
                Toggle("최근 사용 추이",isOn:$store.prefs.showConsumption)
                Toggle("고른 사용 기준선",isOn:$store.prefs.showPaceGuide)
                Toggle("아래 상태 표시줄",isOn:$store.prefs.showFooter)
            }.font(.system(size:12))
        }.animation(Motion.navigate,value:store.prefs.singleColumn).animation(Motion.navigate,value:store.prefs.resetStyle)
    }
    private func selector(_ title:String,choice:Binding<String?>,fallback:String,stream:Stream,allowHidden:Bool)->some View {
        let selected = choice.wrappedValue ?? fallback
        var choices:[(String,String)] = [("auto","자동 · 최소 잔여"),("short","단기 · 최소 잔여"),("week","주간 · 최소 잔여"),("month","월간 · 최소 잔여")]
        if fallback == "long" {choices.insert(("long","장기 · 자동"),at:1)}
        let windows = store.readings[stream.id]?.windows.filter{WindowLogic.remaining($0) != nil} ?? []
        choices += windows.map{("id:"+$0.id,[WindowLogic.label($0),$0.scope ?? "전체"].compactMap{$0}.joined(separator:" · "))}
        if allowHidden {choices.append(("none","표시 안 함"))}
        return VStack(alignment:.leading,spacing:10) {
            HStack {
                Text(title).font(.system(size:12,weight:.semibold))
                Spacer()
                if let w = WindowLogic.selected(windows,choice:selected) {Text((WindowLogic.remaining(w).map{String(Int($0.rounded()))+"% · "} ?? "")+WindowLogic.label(w)).font(.system(size:10)).monospacedDigit().foregroundStyle(Ink.secondary)}
            }
            LazyVGrid(columns:[GridItem(.adaptive(minimum:135))],alignment:.leading,spacing:7) {
                ForEach(choices,id:\.0) {key,label in
                    Button {withAnimation(Motion.feedback){choice.wrappedValue = key}} label: {
                        HStack(spacing:6) {Text(label).font(.system(size:11)).lineLimit(1);Spacer(minLength:0);if selected == key {Image(systemName:"checkmark").font(.system(size:9,weight:.semibold))}}
                            .padding(.horizontal,10).frame(height:32)
                            .background(Color.white.opacity(selected == key ? 0.11 : 0.025),in:RoundedRectangle(cornerRadius:7))
                    }.buttonStyle(TeumPressStyle()).accessibilityAddTraits(selected == key ? [.isSelected] : [])
                }
            }
            if selected == "auto" {
                Text("이 계정이 제공하는 한도 중 가장 적게 남은 값을 자동으로 표시합니다.").font(.system(size:10)).foregroundStyle(Ink.secondary)
            }
            if !windows.isEmpty,selected != "none",WindowLogic.selected(windows,choice:selected) == nil {
                Text("이 계정이 제공하지 않는 주기입니다. 숫자 대신 ‘해당 없음’으로 표시합니다.").font(.system(size:10)).foregroundStyle(Ink.secondary)
            }
        }
    }
}
