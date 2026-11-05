import SwiftUI
import AppKit
import QuotaCore

enum Motion {
    static var feedback:Animation { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .linear(duration:0.08) : .easeOut(duration:0.16) }
    static var navigate:Animation { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .linear(duration:0.1) : .spring(response:0.36,dampingFraction:0.9) }
}

struct TeumPressStyle:ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    func makeBody(configuration:Configuration) -> some View {
        configuration.label.opacity(!enabled ? 0.3 : configuration.isPressed ? 0.65 : 1)
            .background(hovering && enabled ? Color.white.opacity(0.04) : .clear,in:RoundedRectangle(cornerRadius:8))
            .onHover {value in withAnimation(Motion.feedback){hovering = value}}
            .scaleEffect(configuration.isPressed && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.96 : 1)
            .contentShape(Rectangle())
            .animation(Motion.feedback,value:configuration.isPressed)
    }
}

struct TeumActionStyle:ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration:Configuration)->some View {
        configuration.label.font(.system(size:11,weight:.medium)).padding(.horizontal,12).padding(.vertical,8)
            .background(Color.white.opacity(configuration.isPressed ? 0.16 : 0.08),in:RoundedRectangle(cornerRadius:8))
            .opacity(enabled ? 1 : 0.4).scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(Motion.feedback,value:configuration.isPressed)
    }
}

struct TeumTogglePressStyle:ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration:Configuration)->some View {
        configuration.label.opacity(!enabled ? 0.3 : configuration.isPressed ? 0.78 : 1)
            .animation(Motion.feedback,value:configuration.isPressed)
    }
}
struct TeumSwitchKnob:View {
    var isOn:Bool
    @State private var hovering = false
    var body:some View {
        Capsule().fill(isOn ? Color.white.opacity(0.88) : Color.white.opacity(0.12))
            .frame(width:28,height:17)
            .overlay {Capsule().strokeBorder(Color.white.opacity(hovering ? 0.25 : 0),lineWidth:1)}
            .onHover {value in withAnimation(Motion.feedback){hovering = value}}
            .overlay(alignment:isOn ? .trailing : .leading) {
                Circle().fill(isOn ? Color.black : Ink.secondary).frame(width:13,height:13).padding(2)
            }
    }
}
struct TeumSwitch:ToggleStyle {
    var compact = false
    func makeBody(configuration:Configuration) -> some View {
        Button {withAnimation(Motion.feedback){configuration.isOn.toggle()}} label: {
            if compact {TeumSwitchKnob(isOn:configuration.isOn)}
            else {HStack(spacing:12){configuration.label;Spacer(minLength:8);TeumSwitchKnob(isOn:configuration.isOn)}.contentShape(Rectangle())}
        }.buttonStyle(TeumTogglePressStyle()).accessibilityValue(configuration.isOn ? "켜짐" : "꺼짐")
            .accessibilityAddTraits(configuration.isOn ? [.isSelected] : [])
    }
}

struct SettingsView:View {
    @ObservedObject var store:QuotaStore
    @State private var tab:Int
    @State private var editingColor:String? = nil
    @Namespace private var navigation
    @Namespace private var modeSelection
    var initialAccount:String? = nil
    var loginChanged:(Bool)->Void
    var quit:()->Void
    init(store:QuotaStore,loginChanged:@escaping(Bool)->Void = {_ in},quit:@escaping()->Void = {},initialTab:Int = 1,initialAccount:String? = nil) {
        self.initialAccount = initialAccount;self.store = store;self.loginChanged = loginChanged;self.quit = quit;_tab = State(initialValue:initialTab)
    }
    private var title:String {tab == 0 ? "계정과 순서" : tab == 1 ? "나만의 노치" : tab == 3 ? "표시할 정보" : tab == 4 ? "연결" : tab == 5 ? "세션 알림" : tab == 6 ? "사용 목표와 우선순위" : "알림과 실행"}
    private var subtitle:String {tab == 0 ? "AI 계정을 원하는 순서로 놓으세요." : tab == 1 ? "작게 머물다가, 필요한 순간 펼쳐집니다." : tab == 3 ? "각 계정에서 보고 싶은 사용량만 고릅니다." : tab == 4 ? "사용 중인 CLI와 앱의 로그인 상태를 확인합니다." : tab == 5 ? "이번 작업에서만 약속한 조건을 확인합니다." : tab == 6 ? "자동 배분에 나의 선호와 일일 목표를 더합니다." : "알림은 필요한 계정에서만 받으세요."}
    var body:some View {
        HStack(spacing:0) {
            VStack(alignment:.leading,spacing:6) {
                Text("Teum").font(.system(size:26,weight:.semibold)).padding(.bottom,3)
                Text("AI 사이의 작은 틈").font(.system(size:11)).foregroundStyle(Ink.secondary).padding(.bottom,30)
                nav("나만의 노치",symbol:"menubar.rectangle",id:1)
                nav("계정과 순서",symbol:"line.3.horizontal",id:0)
                nav("표시할 정보",symbol:"slider.horizontal.3",id:3)
                nav("연결",symbol:"link",id:4)
                nav("알림과 실행",symbol:"bell",id:2)
                nav("세션 알림",symbol:"bell.badge",id:5)
                nav("목표·선호 AI",symbol:"target",id:6)
                Spacer()
                HStack(spacing:6){Circle().fill(Color.green.opacity(0.75)).frame(width:5,height:5);Text("이 Mac에서만 저장")}.font(.system(size:10)).foregroundStyle(Ink.secondary)
                Button("Teum 종료",action:quit).font(.system(size:11)).foregroundStyle(Ink.secondary).buttonStyle(TeumPressStyle()).padding(.top,10)
            }.padding(.horizontal,22).padding(.top,52).padding(.bottom,26).frame(width:174).background(Color.black.opacity(0.18))
            Rectangle().fill(Ink.rule).frame(width:1)
            VStack(alignment:.leading,spacing:0) {
                VStack(alignment:.leading,spacing:7) {
                    Text(title).font(.system(size:23,weight:.semibold))
                    Text(subtitle).font(.system(size:12)).foregroundStyle(Ink.secondary)
                }.id(tab).transition(.opacity).padding(.horizontal,30).padding(.top,36).padding(.bottom,24)
                if tab == 0 {accountHeader.padding(.horizontal,30)}
                ScrollView {
                    VStack(alignment:.leading,spacing:26) {
                        if tab == 0 {accounts}
                        else if tab == 1 {appearance}
                        else if tab == 3 {UsageDisplaySettings(store:store,initialID:initialAccount)}
                        else if tab == 4 {ConnectionSettings(store:store)}
                        else if tab == 5 {SessionWatchSettings(directory:store.directory,streams:store.prefs.streams)}
                        else if tab == 6 {DailyGoalSettings(store:store)}
                        else {alerts}
                    }.padding(.horizontal,30).padding(.bottom,24)
                        .frame(maxWidth:.infinity,alignment:.leading)
                        .id(tab).transition(.opacity.combined(with:.offset(y:6)))
                }.clipped()
                HStack(spacing:6) {
                    Image(systemName:store.saveError == nil ? "checkmark" : "exclamationmark.circle")
                    Text(store.saveError ?? "변경 사항이 자동 저장됩니다")
                    Spacer()
                }.font(.system(size:10)).foregroundStyle(store.saveError == nil ? Ink.secondary : Ink.red).padding(.horizontal,30).padding(.vertical,16)
            }
        }.frame(width:880,height:680).background(Ink.ground).foregroundStyle(Ink.text).environment(\.colorScheme,.dark).ignoresSafeArea()
            .toggleStyle(TeumSwitch())
            .onChange(of:store.prefs){_,_ in store.save();store.schedule()}
    }
    private func nav(_ name:String,symbol:String,id:Int)->some View {
        Button {withAnimation(Motion.navigate){tab = id}} label: {
            HStack(spacing:10) {Image(systemName:symbol).font(.system(size:13)).frame(width:18);Text(name).font(.system(size:12,weight:tab == id ? .medium : .regular));Spacer(minLength:0)}
                .padding(.horizontal,12).frame(height:38)
                .background {if tab == id {RoundedRectangle(cornerRadius:9).fill(Color.white.opacity(0.09)).matchedGeometryEffect(id:"nav",in:navigation)}}
                .foregroundStyle(tab == id ? Ink.text : Ink.secondary).contentShape(Rectangle())
        }.buttonStyle(TeumPressStyle()).accessibilityAddTraits(tab == id ? [.isSelected] : [])
    }
    private var preview:some View {
        VStack(spacing:14) {
            NotchStrip(store:store,notchWidth:NotchLayout.cameraGap(store.prefs,detected:0),height:32)
                .fixedSize().shadow(color:.black.opacity(0.2),radius:8,y:5)
                .animation(Motion.navigate,value:store.prefs)
            HStack(spacing:5){Image(systemName:"cursorarrow.rays");Text("실제 표시 · 마우스를 올리면 모든 계정 펼치기")}.font(.system(size:10)).foregroundStyle(Ink.secondary)
        }.frame(maxWidth:.infinity).frame(height:98).background(Color.white.opacity(0.025),in:RoundedRectangle(cornerRadius:14))
    }
    private var appearance:some View {
        Group {
            preview
            Toggle("노치에 표시",isOn:$store.prefs.notchEnabled).font(.system(size:12,weight:.medium))
            section("접혀 있을 때") {
                HStack(spacing:8) {
                    mode("숫자 + 막대",symbol:"chart.bar.xaxis",id:"mixed")
                    mode("숫자 2개",symbol:"number",id:"compactNumbers")
                    mode("숫자 4개",symbol:"square.grid.2x2",id:"fourNumbers")
                    mode("미니 막대",symbol:"chart.bar",id:"bars")
                    mode("전체 숫자",symbol:"textformat.123",id:"allNumbers")
                }
                if ["compactNumbers","mixed","fourNumbers"].contains(store.prefs.notchStyle) {
                    VStack(alignment:.leading,spacing:12) {
                        HStack(spacing:16) {
                            ForEach(Array(store.numberStreams.enumerated()),id:\.element.id) {index,s in
                                HStack(spacing:7){Text("\(index+1)").font(.system(size:10)).foregroundStyle(Ink.secondary);BrandMark(stream:s,size:16);Text(s.name).font(.system(size:12,weight:.medium)).lineLimit(1)}
                            }
                            Spacer()
                            Button("순서 바꾸기") {withAnimation(Motion.navigate){tab = 0}}.buttonStyle(TeumActionStyle())
                        }
                        Text(store.prefs.notchStyle == "fourNumbers" ? "노치 대상 앞의 네 계정을 카메라 양쪽에 두 개씩 표시합니다. 순서를 바꾸면 함께 바뀌어요." : "노치에 표시한 계정 중 앞의 두 개가 숫자로 뜹니다. 순서를 바꾸면 함께 바뀌어요.").font(.system(size:11)).foregroundStyle(Ink.secondary)
                    }.transition(.opacity.combined(with:.move(edge:.top)))
                }
                Toggle("내용에 맞춰 여백 줄이기",isOn:$store.prefs.fitNotch)
                if !store.prefs.fitNotch {slider("양쪽 여유 폭",value:$store.prefs.wingWidth,range:38...160,unit:"pt")}
            }
            section("양쪽 여백") {
                slider("왼쪽 여백",value:$store.prefs.leftPadding,range:8...32,unit:"pt")
                slider("오른쪽 여백",value:$store.prefs.rightPadding,range:8...32,unit:"pt")
                Text("카메라 영역과 바깥 끝 사이의 중앙에 각 요소를 놓습니다.").font(.system(size:11)).foregroundStyle(Ink.secondary)
            }
            section("카메라 주변") {
                slider("카메라 영역",value:$store.prefs.cameraWidth,range:100...260,unit:"pt")
                slider("옆 여백",value:$store.prefs.cameraPadding,range:0...20,unit:"pt")
                Text("가운데는 카메라를 위해 비웁니다. 가려진다면 영역을 넓혀 주세요.").font(.system(size:11)).foregroundStyle(Ink.secondary)
            }
            section("펼쳐진 화면") {
                Toggle("행 간격 줄이기",isOn:$store.prefs.compact)
                Toggle("리셋까지 남은 시간",isOn:$store.prefs.showResets)
                Toggle("계정 이메일",isOn:$store.prefs.showAccount)
                Toggle("경고 제외 계정도 표시",isOn:$store.prefs.showExcluded)
                slider("펼침 너비",value:$store.prefs.panelWidth,range:560...720,unit:"pt")
                slider("열리기까지",value:$store.prefs.hoverDelay,range:0...0.6,unit:"초")
                slider("닫히기까지",value:$store.prefs.closeDelay,range:0.15...1.2,unit:"초")
            }
        }.font(.system(size:12)).animation(Motion.navigate,value:store.prefs.notchStyle).animation(Motion.navigate,value:store.prefs.fitNotch)
    }
    private func mode(_ name:String,symbol:String,id:String)->some View {
        Button {withAnimation(Motion.navigate){store.prefs.notchStyle = id}} label: {
            HStack(spacing:6){Image(systemName:symbol).font(.system(size:11));Text(name).font(.system(size:12,weight:.medium))}
                .frame(maxWidth:.infinity).frame(height:36)
                .background {if store.prefs.notchStyle == id {RoundedRectangle(cornerRadius:9).fill(Color.white.opacity(0.12)).matchedGeometryEffect(id:"mode",in:modeSelection)}else{RoundedRectangle(cornerRadius:9).fill(Color.white.opacity(0.025))}}
                .foregroundStyle(store.prefs.notchStyle == id ? Ink.text : Ink.secondary)
        }.buttonStyle(TeumPressStyle()).accessibilityAddTraits(store.prefs.notchStyle == id ? [.isSelected] : [])
    }
    private var accountHeader:some View {
        VStack(alignment:.leading,spacing:15) {
            Text("이름을 눌러 수정하고, 위아래 버튼으로 순서를 바꿉니다.").font(.system(size:11)).foregroundStyle(Ink.secondary)
            HStack(spacing:10) {
                Text(store.notchNumberCount == 0 ? "계정" : "계정 · 앞의 \(store.notchNumberCount)개가 숫자로 표시").frame(maxWidth:.infinity,alignment:.leading)
                Text("색").frame(width:28)
                Text("표시").frame(width:40)
                Text("경고").frame(width:40)
                Text("노치").frame(width:40)
                Text("순서").frame(width:64)
            }.font(.system(size:10,weight:.medium)).foregroundStyle(Ink.secondary)
            Rectangle().fill(Ink.rule).frame(height:0.5)
        }.padding(.bottom,2)
    }
    private var accounts:some View {
        VStack(alignment:.leading,spacing:0) {
            ForEach($store.prefs.streams) {$stream in
                HStack(spacing:10) {
                    BrandMark(stream:stream,size:22).frame(width:28)
                    VStack(alignment:.leading,spacing:5) {
                        HStack(spacing:7) {
                            TextField("계정 이름",text:$stream.name).textFieldStyle(.plain).font(.system(size:13,weight:.medium))
                            if let index = store.numberStreams.firstIndex(where:{$0.id == stream.id}) {
                                Text("숫자 \(index+1)").font(.system(size:9,weight:.medium)).foregroundStyle(Ink.text).padding(.horizontal,6).padding(.vertical,3).background(Color.white.opacity(0.07),in:RoundedRectangle(cornerRadius:4)).fixedSize()
                            }
                        }
                        Text(stream.origin).font(.system(size:10)).foregroundStyle(Ink.secondary)
                    }.frame(maxWidth:.infinity,alignment:.leading)
                    Button {withAnimation(Motion.feedback){editingColor = stream.id}} label: {
                        Circle().fill(stream.tint).frame(width:15,height:15).overlay(Circle().strokeBorder(Color.white.opacity(0.2),lineWidth:0.5)).frame(width:28,height:28)
                    }.buttonStyle(TeumPressStyle()).help("\(stream.name) 표시 색 바꾸기").accessibilityLabel("\(stream.name) 표시 색 바꾸기")
                        .popover(isPresented:Binding(get:{editingColor == stream.id},set:{if !$0 {editingColor = nil}}),arrowEdge:.trailing) {colorEditor($stream)}
                    Toggle("\(stream.name) 표시",isOn:$stream.visible).labelsHidden().toggleStyle(TeumSwitch(compact:true)).frame(width:40)
                    Toggle("\(stream.name) 잔여량 경고",isOn:$stream.warns).labelsHidden().toggleStyle(TeumSwitch(compact:true)).frame(width:40).help("잔여량 부족·소진 경고입니다. 리셋 알림은 ‘알림과 실행’에서 따로 설정합니다.")
                    Toggle("\(stream.name) 노치",isOn:$stream.pinned).labelsHidden().toggleStyle(TeumSwitch(compact:true)).frame(width:40)
                    HStack(spacing:0) {
                        GlyphButton(symbol:"chevron.up",help:"\(stream.name) 위로") {withAnimation(Motion.navigate){store.move(stream.id,by:-1)}}.disabled(stream.id == store.prefs.streams.first?.id)
                        GlyphButton(symbol:"chevron.down",help:"\(stream.name) 아래로") {withAnimation(Motion.navigate){store.move(stream.id,by:1)}}.disabled(stream.id == store.prefs.streams.last?.id)
                    }.frame(width:64)
                }.frame(height:54).background(initialAccount == stream.id ? Color.white.opacity(0.035) : .clear,in:RoundedRectangle(cornerRadius:8))
                Rectangle().fill(Ink.rule).frame(height:0.5)
            }
        }
    }
    private func colorEditor(_ stream:Binding<Stream>)->some View {
        VStack(alignment:.leading,spacing:16) {
            Text(stream.wrappedValue.name+" 표시 색").font(.system(size:13,weight:.semibold))
            LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:12),count:4),spacing:12) {
                ForEach(["E0916B","7CCDB5","BDA3F5","7AB2F5","79C2E8","63C9C9","E0B0F0","F3B968"],id:\.self) {hex in
                    Button {withAnimation(Motion.feedback){stream.wrappedValue.colorHex = hex}} label: {
                        Circle().fill(Stream.color(hex) ?? .white).frame(width:28,height:28)
                            .overlay {if stream.wrappedValue.colorHex == hex {Image(systemName:"checkmark").font(.system(size:11,weight:.bold)).foregroundStyle(.black)}}
                    }.buttonStyle(TeumPressStyle()).help("색 #\(hex)").accessibilityLabel("색 #\(hex)")
                }
            }
            ColorPicker("직접 선택",selection:Binding(get:{stream.wrappedValue.tint},set:{color in
                guard let rgb = NSColor(color).usingColorSpace(.sRGB) else{return}
                stream.wrappedValue.colorHex = String(format:"%02X%02X%02X",Int((rgb.redComponent*255).rounded()),Int((rgb.greenComponent*255).rounded()),Int((rgb.blueComponent*255).rounded()))
            }),supportsOpacity:false).font(.system(size:11)).help("직접 색 선택")
            Button("서비스 기본색으로") {withAnimation(Motion.feedback){stream.wrappedValue.colorHex = nil;editingColor = nil}}.font(.system(size:11)).foregroundStyle(Ink.secondary).buttonStyle(TeumPressStyle())
        }.padding(18).frame(width:210).foregroundStyle(Ink.text).environment(\.colorScheme,.dark)
    }
    private var alerts:some View {
        Group {
            section("노치 알림") {
                Toggle("노치에서 펼쳐서 알리기",isOn:$store.prefs.islandNotices)
                Toggle("한도가 리셋됐을 때",isOn:$store.prefs.resetNotices)
                Toggle("잔여량 부족·소진",isOn:$store.prefs.lowNotices)
                slider("알림 표시 시간",value:$store.prefs.noticeSeconds,range:2...10,unit:"초")
                HStack(spacing:10) {
                    Button("리셋 미리보기") {preview(.reset)}
                    Button("부족 알림 미리보기") {preview(.low)}
                }.buttonStyle(TeumActionStyle()).disabled(!store.prefs.notchEnabled)
            }
            section("사용 속도와 오늘 목표") {
                Toggle("고른 사용 기준 아래로 내려갔을 때",isOn:$store.prefs.paceNotices)
                Toggle("오늘 목표가 얼마 남지 않았을 때",isOn:$store.prefs.goalNearNotices)
                slider("목표 근접 · 목표의 남은 비율",value:$store.prefs.goalRemainingThreshold,range:5...50,unit:"%")
                    .disabled(!store.prefs.goalNearNotices)
                Toggle("오늘 사용 목표에 도달했을 때",isOn:$store.prefs.goalReachedNotices)
                Text("근접 기준 20%는 오늘 목표의 80%를 썼다는 뜻입니다. 새 사용량이 기준을 넘을 때 노치가 펼쳐지고, 같은 주기·날짜에는 같은 알림을 반복하지 않습니다. 계정의 부족 알림 설정도 따릅니다.").font(.system(size:11)).foregroundStyle(Ink.secondary).fixedSize(horizontal:false,vertical:true)
                HStack(spacing:10) {
                    Button("사용 속도 미리보기") {preview(.pace)}
                    Button("목표 알림 미리보기") {preview(.goalNear)}
                }.buttonStyle(TeumActionStyle()).disabled(!store.prefs.notchEnabled)
            }
            section("계정별 노치 알림") {
                HStack {Text("계정");Spacer();Text("리셋").frame(width:44);Text("부족").frame(width:44)}.font(.system(size:10)).foregroundStyle(Ink.secondary)
                ForEach($store.prefs.streams) {$stream in
                    HStack(spacing:12) {
                        BrandMark(stream:stream,size:16);Text(stream.name).font(.system(size:12));Spacer()
                        Toggle("\(stream.name) 리셋 알림",isOn:Binding(get:{stream.notifyReset != false},set:{stream.notifyReset = $0})).labelsHidden().toggleStyle(TeumSwitch(compact:true)).frame(width:44)
                        Toggle("\(stream.name) 부족 알림",isOn:Binding(get:{stream.notifyLow != false},set:{stream.notifyLow = $0})).labelsHidden().toggleStyle(TeumSwitch(compact:true)).frame(width:44)
                    }.frame(height:30)
                }
                Text("부족 알림은 계정의 경고 설정도 따릅니다. 한도별 제외는 계정 상세에서 바꿀 수 있어요.").font(.system(size:11)).foregroundStyle(Ink.secondary)
            }
            section("필요한 경고만") {
                slider("잔여량 기준",value:$store.prefs.threshold,range:1...50,unit:"%")
                Toggle("macOS 알림 보내기",isOn:$store.prefs.notifications)
                Text("오래된 값으로 경고하지 않습니다. 각 한도의 경고는 계정 상세에서 바꿀 수 있어요.").font(.system(size:11)).foregroundStyle(Ink.secondary)
            }
            section("실행") {
                Toggle("로그인할 때 시작",isOn:Binding(get:{store.prefs.launchAtLogin},set:loginChanged))
                slider("새로고침 간격",value:$store.prefs.refreshMinutes,range:1...15,unit:"분")
                HStack(spacing:18) {
                    Button("지금 새로고침") {Task{await store.refresh()}}.disabled(store.refreshing)
                    Button("클로드 연결 허용") {Task{_ = await LocalCredentials.authorizeClaudeAccessAsync();await store.refresh()}}
                }.buttonStyle(TeumActionStyle()).controlSize(.small)
            }
            section("AI 연결") {
                Text("teum-cli가 같은 사용량을 읽습니다.").font(.system(size:13,weight:.medium))
                Text("연결된 AI는 남은 사용량을 참고합니다. 모델과 실행 간격의 실제 조절은 teum-cli run으로 시작한 작업에 적용됩니다.").font(.system(size:12)).foregroundStyle(Ink.secondary).fixedSize(horizontal:false,vertical:true)
                Text("teum-cli status").font(.system(size:11,design:.monospaced)).foregroundStyle(Ink.secondary).textSelection(.enabled)
            }
        }.font(.system(size:12))
    }
    private func preview(_ kind:IslandNotice.Kind) {
        guard let s = store.prefs.streams.first else{return}
        store.previewNotice?(IslandNotice(stream:s,windowID:"preview",kind:kind,before:kind == .reset ? 12 : 22,remaining:kind == .reset ? 100 : 8,detail:"미리보기 · 실제 사용량은 그대로"))
    }
    private func section<C:View>(_ title:String,@ViewBuilder content:()->C)->some View {
        VStack(alignment:.leading,spacing:15) {
            HStack(spacing:12){Text(title).font(.system(size:12,weight:.semibold));Rectangle().fill(Ink.rule).frame(height:1)}
            content()
        }
    }
    private func slider(_ title:String,value:Binding<Double>,range:ClosedRange<Double>,unit:String)->some View {
        VStack(spacing:7) {
            HStack {Text(title);Spacer();Text(unit == "초" ? String(format:"%.2f초",value.wrappedValue) : "\(Int(value.wrappedValue))\(unit)").monospacedDigit().foregroundStyle(Ink.secondary)}
            Slider(value:Binding(get:{value.wrappedValue},set:{value.wrappedValue = unit == "초" ? ($0*20).rounded()/20 : $0.rounded()}),in:range).tint(Color.white.opacity(0.65))
        }.font(.system(size:11))
    }
}
