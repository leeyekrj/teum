import SwiftUI
import AppKit
import QuotaModel
import QuotaCore

enum Ink {
    static let ground = Color(red:0.065,green:0.071,blue:0.085)
    static let text = Color(red:0.95,green:0.96,blue:0.98)
    static let secondary = Color(red:0.64,green:0.68,blue:0.74)
    static let rule = Color.white.opacity(0.09)
    static let selected = Color(red:0.17,green:0.23,blue:0.32)
    static let amber = Color(red:1,green:0.73,blue:0.40)
    static let red = Color(red:1,green:0.48,blue:0.46)
}

enum MeterLayout {
    static let trackHeight:CGFloat = 3
    static let guideHeight:CGFloat = 7
    static let textGap:CGFloat = 7
    /// Two summary columns of (width - 304)/2: at 604pt, 150pt holds a 81pt
    /// calendar reset time with "05:55 소진 예정" (63pt) beside it, and the
    /// 158pt account column still fits the longest name and plan.
    static func column(_ panelWidth:CGFloat,single:Bool)->CGFloat {single ? panelWidth-310 : (panelWidth-304)/2}
}

private enum BrandAssets {
    static let cache = NSCache<NSString,NSImage>()
    static func image(named name:String)->NSImage? {
        if let image = cache.object(forKey:name as NSString) {return image}
        var paths = [Bundle.main.resourceURL?.appendingPathComponent("logos/\(name).png")]
        #if DEBUG
        paths.append(URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Resources/logos/\(name).png"))
        #endif
        for case let url? in paths {
            if let image = NSImage(contentsOf:url) {cache.setObject(image,forKey:name as NSString);return image}
        }
        return nil
    }
}

struct BrandMark:View {
    let stream:Stream
    var size:CGFloat = 18
    private var asset:NSImage? {
        let name = stream.source == "codex" ? "codex-knot" : stream.source == "agy" ? "antigravity" : stream.source
        return BrandAssets.image(named:name)
    }
    var body:some View {
        Group {
            if let asset {Image(nsImage:asset).resizable().renderingMode(["codex","grok"].contains(stream.source) ? .template : .original).scaledToFit().foregroundStyle(.white)}
            else {Image(systemName:stream.symbol).resizable().scaledToFit().foregroundStyle(stream.tint)}
        }.frame(width:size,height:size).accessibilityLabel(stream.origin)
    }
}

struct GlyphButton: View {
    let symbol: String
    let help: String
    var active = false
    var size:CGFloat = 28
    let action: () -> Void
    var body: some View {
        Button(action:action) { Image(systemName:symbol).font(.system(size:12,weight:.medium)).foregroundStyle(active ? Ink.text : Ink.secondary).frame(width:size,height:28).background(active ? Ink.selected : .clear,in:RoundedRectangle(cornerRadius:7)) }
            .buttonStyle(TeumPressStyle()).help(help).accessibilityLabel(help)
    }
}

struct QuotaPanel: View {
    @ObservedObject var store: QuotaStore
    @ObservedObject private var navigation: PanelNavigation
    // Held, not observed: the account detail is page 0's own business.
    @State private var selection: PanelSelection
    @State var held: Bool
    let toggleHold: () -> Void
    let settings: () -> Void
    let accountSettings: (String) -> Void
    let planSettings: () -> Void
    let close: () -> Void
    var demo = false
    var embedded = false
    var initialPage:Int = 0
    var cameraGap:CGFloat = 0
    var heightOverride:CGFloat? = nil
    init(store:QuotaStore,held:Bool,toggleHold:@escaping ()->Void,settings:@escaping ()->Void,close:@escaping ()->Void,demo:Bool = false,initialSelection:String? = nil,initialPage:Int = 0,embedded:Bool = false,cameraGap:CGFloat = 0,heightOverride:CGFloat? = nil,accountSettings:((String)->Void)? = nil,planSettings:(()->Void)? = nil) {
        self.store = store;_navigation = ObservedObject(wrappedValue:store.navigation)
        _held = State(initialValue:held);self.toggleHold = toggleHold;self.settings = settings;self.accountSettings = accountSettings ?? {_ in settings()};self.close = close;self.demo = demo
        self.embedded = embedded;self.initialPage = initialPage;self.cameraGap = cameraGap;self.heightOverride = heightOverride
        self.planSettings = planSettings ?? settings
        _selection = State(initialValue:PanelSelection(initialSelection))
    }
    var body: some View {
        TimelineView(.periodic(from:.now,by:30)) { _ in
            VStack(spacing:0) {
                header.padding(.horizontal,36).padding(.top,18).padding(.bottom,16)
                // Every page stays mounted; a page change moves layers on the compositor.
                PageCarousel(page:navigation.page,direction:navigation.direction,animated:navigation.animated,make:makePage,settled:pageSettled)
                    .frame(maxWidth:.infinity,maxHeight:.infinity)
                    .background {if SwipeTrace.enabled {PageLayoutProbe(page:navigation.page)}}
                if store.prefs.showFooter {
                    Rectangle().fill(Ink.rule).frame(height:1).padding(.horizontal,36)
                }
                ZStack {
                    if store.prefs.showFooter {footer.padding(.horizontal,36)}
                    pageDots
                }.frame(height:store.prefs.showFooter ? 44 : 28)
            }
            .animation(Motion.feedback,value:store.refreshing)
            .frame(width:store.prefs.panelWidth,height:heightOverride ?? store.panelHeight,alignment:.top)
            .background(Color.black)
            .foregroundStyle(Ink.text)
            .clipShape(RoundedRectangle(cornerRadius:22,style:.continuous))
            .environment(\.colorScheme,.dark)
            .background(PanelSwipeBridge(turn:turnPage))
            .accessibilityAction(named:Text("다음 페이지")){turnPage(1)}
            .accessibilityAction(named:Text("이전 페이지")){turnPage(-1)}
            .onAppear {if initialPage != 0 {navigation.go(to:initialPage,animated:false)}}
        }
    }
    private func turnPage(_ step:Int) {
        let from = navigation.page
        let target = PanelPages.next(from,by:step);guard target != from else{return}
        SwipeTrace.record("page-requested",fields:["from":from,"to":target])
        StallProbe.watch(["from":from,"to":target])
        // No SwiftUI transaction: the chrome updates once and the pages slide on the compositor.
        navigation.go(to:target,step:step)
    }
    private func makePage(_ page:Int)->NSView {
        let content:AnyView
        switch page {
        case 1:content = AnyView(HistoryPage(store:store))
        case 2:content = AnyView(DailyGoalProgress(store:store,goals:store.dailyGoals,openSettings:planSettings))
        case 3:content = AnyView(QuotaPlanView(store:store,openSettings:planSettings))
        default:content = AnyView(QuotaSummaryPage(store:store,selection:selection,demo:demo,settings:settings,accountSettings:accountSettings))
        }
        let host = InteractiveHost(rootView:PageSurface(content:content))
        host.sizingOptions = [];host.appearance = NSAppearance(named:.darkAqua)
        return host
    }
    private func pageSettled(_ page:Int) {
        // Clear the detail only once page 0 has slid away, so it never swaps mid-slide.
        if page != 0,selection.account != nil {selection.account = nil}
        switch page {
        case 1:Task {await store.tokenHistory.load(streams:store.prefs.streams)}
        case 2,3:store.dailyGoals.observe(prefs:store.prefs,readings:store.readings)
        default:break
        }
    }
    private var headerSide:CGFloat {max(80,(store.prefs.panelWidth-cameraGap)/2-36)}
    private var toolbarSize:CGFloat {cameraGap>0 ? min(28,max(18,(headerSide-12)/4)) : 28}
    private var header: some View {
        HStack(spacing:0) {
            title.frame(maxWidth:cameraGap>0 ? headerSide : .infinity,alignment:.leading)
            if cameraGap>0 {Color.clear.frame(width:cameraGap)} else {Spacer(minLength:8)}
            toolbar.frame(maxWidth:cameraGap>0 ? headerSide : nil,alignment:.trailing)
        }.frame(height:28)
    }
    private var title:some View {
        HStack(spacing:7) {
            Text("Teum").font(.system(size:21,weight:.semibold)).fixedSize()
            Text(demo ? "예시 데이터" : navigation.page == 1 ? "로컬 기록" : navigation.page == 2 ? "오늘의 목표" : navigation.page == 3 ? "배분 계획" : "남은 사용량").font(.system(size:11)).foregroundStyle(Ink.secondary).lineLimit(1)
        }
    }
    private var toolbar:some View {
        HStack(spacing:4) {
            if navigation.page == 1 {HistoryRefreshButton(history:store.tokenHistory,streams:store.prefs.streams,size:toolbarSize)}
            else if store.refreshing {ProgressView().controlSize(.small).scaleEffect(0.7).frame(width:toolbarSize)}
            else {GlyphButton(symbol:"arrow.clockwise",help:"모든 계정 새로고침",size:toolbarSize){Task{await store.refresh()}}}
            GlyphButton(symbol:held ? "pin.fill" : "pin",help:held ? "패널 고정 해제" : "패널 고정",active:held,size:toolbarSize){withAnimation(Motion.feedback){held.toggle();toggleHold()}}
            GlyphButton(symbol:"gearshape",help:"설정 열기",size:toolbarSize,action:settings)
            GlyphButton(symbol:"xmark",help:"패널 닫기",size:toolbarSize,action:close)
        }
    }
    private var pageDots:some View {
        HStack(spacing:0) {
            ForEach(0..<PanelPages.titles.count,id:\.self) {page in
                Button {turnPage(page-navigation.page)} label:{
                    Circle().fill(navigation.page == page ? Ink.text : Ink.secondary.opacity(0.35))
                        .frame(width:5,height:5).frame(width:24,height:28).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(PanelPages.titles[page]+" 페이지로 이동")
                    .accessibilityAddTraits(navigation.page == page ? [.isSelected] : [])
                    .help(PanelPages.titles[page]+" · 좌우로 쓸어 페이지 이동")
            }
        }.animation(Motion.feedback,value:navigation.page)
    }
    private var footer: some View {
        HStack(spacing:0) {
            HStack(spacing:8) {
                if navigation.page == 1 {HistoryStatus(history:store.tokenHistory)}
                else {
                    Circle().fill(store.refreshing ? Ink.amber : Ink.secondary).frame(width:4,height:4)
                    Text(navigation.page == 0 && store.refreshing ? "사용량 확인 중…" : syncLabel).lineLimit(1).truncationMode(.tail)
                }
            }.frame(maxWidth:.infinity,alignment:.leading)
            Color.clear.frame(width:116)
            Text(footerRight).lineLimit(1).truncationMode(.tail).foregroundStyle(navigation.page == 0 && !store.warningStreams.isEmpty ? Ink.amber : Ink.secondary).frame(maxWidth:.infinity,alignment:.trailing)
        }.font(.system(size:10)).foregroundStyle(Ink.secondary)
    }
    private var syncLabel:String {
        guard let date = store.readings.values.compactMap({$0.snapshot?.fetchedAt}).max() else {return "아직 동기화되지 않았어요"}
        let failed = store.prefs.streams.filter{$0.visible && $0.connected != false && store.readings[$0.id]?.error != nil}.count
        let time = Calendar.current.isDateInToday(date) ? date.formatted(.dateTime.hour().minute()) : date.formatted(.dateTime.month(.defaultDigits).day().hour().minute())
        return "동기화 "+time+(failed>0 ? " · 일부 실패" : "")
    }
    private var footerRight:String {
        if navigation.page == 2 {return "관측 사용 · %p 기준"}
        if navigation.page == 3 {return "예상 배분 · %p 기준"}
        if navigation.page == 1 {return "이 Mac의 CLI 기록"}
        if store.saveError != nil {return "저장 실패"}
        if !store.warningStreams.isEmpty {return "잔여 \(Int(store.prefs.threshold))% 이하 \(store.warningStreams.count)개"}
        let count = store.prefs.streams.filter{$0.visible && !$0.warns}.count
        return store.visible.isEmpty ? "설정에서 표시를 켜 주세요" : count>0 ? "경고 제외 \(count)개" : "계정을 눌러 상세 보기"
    }
}

/// The root of each mounted page. Nested hosting views do not inherit the
/// panel's SwiftUI environment, so the page sets its own.
private struct PageSurface:View {
    let content:AnyView
    var body:some View {
        TimelineView(.periodic(from:.now,by:30)) {_ in content}
            .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.top)
            .foregroundStyle(Ink.text)
            .environment(\.colorScheme,.dark)
    }
}

private struct HistoryPage:View {
    @ObservedObject var store:QuotaStore
    var body:some View {TokenHistoryView(history:store.tokenHistory,streams:store.prefs.streams)}
}

private struct HistoryRefreshButton:View {
    @ObservedObject var history:TokenHistoryStore
    let streams:[Stream]
    let size:CGFloat
    var body:some View {
        if history.reading {ProgressView().controlSize(.small).scaleEffect(0.7).frame(width:size)}
        else {GlyphButton(symbol:"arrow.clockwise",help:"토큰 기록 새로고침",size:size){Task{await history.load(streams:streams,force:true)}}}
    }
}

private struct HistoryStatus:View {
    @ObservedObject var history:TokenHistoryStore
    var body:some View {
        Circle().fill(history.reading ? Ink.amber : Ink.secondary).frame(width:4,height:4)
        Text(history.reading ? "로컬 기록 집계 중…" : history.lastRead.map{"기록 확인 "+$0.formatted(.dateTime.month(.defaultDigits).day().hour().minute())} ?? "로컬 기록 읽기 대기").lineLimit(1).truncationMode(.tail)
    }
}

/// Page 0: the account table, or one account's detail.
struct QuotaSummaryPage:View {
    @ObservedObject var store:QuotaStore
    @ObservedObject var selection:PanelSelection
    var demo = false
    let settings:()->Void
    let accountSettings:(String)->Void
    @State private var hovered:String?
    var body:some View {
        ZStack(alignment:.top) {
            if let id = selection.account,let stream = store.prefs.streams.first(where:{$0.id == id}) {
                detail(stream).transition(.asymmetric(insertion:.move(edge:.trailing).combined(with:.opacity),removal:.move(edge:.trailing).combined(with:.opacity)))
            } else {
                overview.transition(.asymmetric(insertion:.move(edge:.leading).combined(with:.opacity),removal:.move(edge:.leading).combined(with:.opacity)))
            }
        }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.top).clipped()
    }
    private var captureSettled:Bool {demo || CommandLine.arguments.contains("--capture")}
    /// Warning exclusions mute the colour, never the forecast itself.
    private func warnable(_ stream:Stream,_ window:UsageWindow)->Bool {stream.warns && !stream.ignoredWindows.contains(window.id)}
    private var overview: some View {
        ScrollView {
        VStack(spacing:0) {
            if !store.visible.isEmpty && !store.prefs.showAllWindows {
            HStack(spacing:16) {
                Text("계정").frame(maxWidth:.infinity,alignment:.leading)
                Text(store.prefs.singleColumn ? "표시할 한도" : "요약").frame(width:meterWidth,alignment:.leading)
                if !store.prefs.singleColumn {Text("추가 한도").frame(width:meterWidth,alignment:.leading)}
                Color.clear.frame(width:18)
            }.frame(height:18).font(.system(size:10,weight:.medium)).foregroundStyle(Ink.secondary).padding(.horizontal,40).padding(.bottom,9)
            Rectangle().fill(Ink.rule).frame(height:1).padding(.horizontal,36)
            }
            if store.visible.isEmpty {
                VStack(spacing:12) {
                    Image(systemName:"line.3.horizontal.decrease.circle").font(.system(size:26)).foregroundStyle(Ink.secondary)
                    Text("표시할 계정이 없어요").font(.system(size:14,weight:.medium))
                    Text("설정에서 계정을 켜거나 경고 제외 항목을 다시 표시해 주세요.").font(.system(size:12)).foregroundStyle(Ink.secondary).multilineTextAlignment(.center)
                    Button("계정 설정 열기",action:settings).buttonStyle(TeumActionStyle())
                }.frame(maxWidth:.infinity).padding(.horizontal,40).padding(.vertical,24)
            } else {
                ForEach(store.visible) { stream in
                    if store.prefs.showAllWindows {fullRow(stream)} else {row(stream)}
                    if stream.id != store.visible.last?.id { Rectangle().fill(Ink.rule).frame(height:0.5).padding(.leading,24).padding(.trailing,24) }
                }
            }
        }
        }.scrollIndicators(.hidden)
    }
    private var meterWidth: CGFloat {MeterLayout.column(store.prefs.panelWidth,single:store.prefs.singleColumn)}
    private func open(_ stream:Stream) {withAnimation(Motion.navigate){selection.account = stream.id}}
    private func row(_ stream: Stream) -> some View {
        let reading = store.readings[stream.id] ?? Reading()
        let stale = reading.stale(minutes:store.prefs.refreshMinutes)
        return Button {open(stream)} label: {HStack(spacing:16) {
            HStack(spacing:10) {
                BrandMark(stream:stream,size:20)
                VStack(alignment:.leading,spacing:4) {
                    Text(stream.name).font(.system(size:12,weight:.medium)).lineLimit(1).truncationMode(.middle)
                    HStack(spacing:4) {
                        if stale && reading.snapshot != nil { Image(systemName:"clock.arrow.circlepath").font(.system(size:9)) }
                        if reading.snapshot == nil {Text(reading.loading ? "확인 중…" : "연결 확인 필요").lineLimit(1)}
                        else {
                            let info = [store.prefs.showAccount ? reading.snapshot?.account : nil,store.prefs.showOrigin ? stream.origin : nil,store.prefs.showPlan ? reading.snapshot?.planName : nil].compactMap{$0}.joined(separator:" · ")
                            if !info.isEmpty {Text(info).lineLimit(1).truncationMode(.middle)}
                        }
                        if stale && reading.snapshot != nil { Text("· 이전 값").fixedSize() }
                    }.font(.system(size:10)).foregroundStyle(stale && reading.snapshot != nil ? Ink.amber : Ink.secondary)
                }
            }.frame(maxWidth:.infinity,alignment:.leading)
            horizon(stream,reading:reading,short:true).frame(width:meterWidth)
            if !store.prefs.singleColumn {horizon(stream,reading:reading,short:false).frame(width:meterWidth)}
            Image(systemName:"chevron.right").font(.system(size:9,weight:.semibold)).foregroundStyle(hovered == stream.id ? Ink.text : Ink.secondary.opacity(0.6)).frame(width:18)
        }
        .padding(.horizontal,40).frame(height:store.prefs.compact ? 48 : 58)
        .background(hovered == stream.id ? Color.white.opacity(0.045) : .clear)
        .contentShape(Rectangle())
        }.buttonStyle(TeumTogglePressStyle())
        .onHover { inside in withAnimation(Motion.feedback){hovered = inside ? stream.id : nil} }
        .accessibilityElement(children:.combine)
        .help("\(stream.name) · 세부 한도와 정확한 리셋 시각 보기")
        .contextMenu {
            Button(stream.warns ? "잔여량 경고 끄기" : "잔여량 경고 켜기") {
                guard let i = store.prefs.streams.firstIndex(where:{$0.id == stream.id}) else { return }
                store.prefs.streams[i].warns.toggle(); store.save()
            }
            Button("설정 열기",action:settings)
        }
    }
    private func fullRow(_ stream:Stream)->some View {
        let reading = store.readings[stream.id] ?? Reading()
        return Button {open(stream)} label: {VStack(alignment:.leading,spacing:12) {
            HStack(spacing:9) {
                BrandMark(stream:stream,size:18)
                Text(stream.name).font(.system(size:12,weight:.semibold))
                if store.prefs.showPlan,let plan = reading.snapshot?.planName {Text(plan).font(.system(size:10)).foregroundStyle(Ink.secondary)}
                Spacer()
                Image(systemName:"chevron.right").font(.system(size:9)).foregroundStyle(Ink.secondary)
            }
            if store.prefs.showAccount,let account = reading.snapshot?.account {Text(account).font(.system(size:10)).foregroundStyle(Ink.secondary).lineLimit(1)}
            if reading.windows.isEmpty {Text(reading.error ?? "사용량 확인 중").font(.system(size:11)).foregroundStyle(Ink.secondary)}
            ForEach(reading.windows) {w in fullWindow(w,stream:stream,reading:reading)}
            if store.prefs.showConsumption,let text = store.consumption(stream.id) {Text(text).font(.system(size:10)).foregroundStyle(Ink.secondary)}
        }.padding(.horizontal,40).padding(.vertical,14)
            .background(hovered == stream.id ? Color.white.opacity(0.04) : .clear)
            .contentShape(Rectangle())
        }.buttonStyle(TeumTogglePressStyle())
            .onHover{value in withAnimation(Motion.feedback){hovered = value ? stream.id : nil}}
            .accessibilityElement(children:.combine)
    }
    private func fullWindow(_ w:UsageWindow,stream:Stream,reading:Reading)->some View {
        let expired = WindowLogic.expired(w,snapshot:reading.snapshot)
        let stale = reading.stale(minutes:store.prefs.refreshMinutes) || expired
        let label = [WindowLogic.label(w),w.scope ?? w.label].compactMap{$0}.joined(separator:" · ")
        let value = WindowLogic.remaining(w)
        let number = value.map{String(Int($0.rounded()))+"%"} ?? w.credit?.amount ?? "—"
        return VStack(spacing:MeterLayout.textGap) {
            HStack(spacing:8) {
                Text(label).lineLimit(1)
                Spacer(minLength:4)
                if store.prefs.showResets {Text(expired ? "리셋 전 기록" : WindowLogic.resetDisplay(w.resetsAt,style:store.prefs.resetStyle,todayTomorrow:store.prefs.resetTodayTomorrow,weekdays:store.prefs.resetWeekdays)).foregroundStyle(expired ? Ink.amber : Ink.secondary).lineLimit(1).fixedSize().layoutPriority(1)}
                if !stale,store.prefs.showRunOut,let runOut = RunOut.date(w) {RunOutLabel(date:runOut,color:warnable(stream,w) ? Ink.amber : Ink.secondary,size:10)}
                Text(number).fontWeight(.semibold).monospacedDigit().foregroundStyle(stale ? Ink.secondary : Ink.text).frame(minWidth:34,alignment:.trailing)
            }.font(.system(size:10))
            if let value {QuotaMeter(value:value,tint:stale ? Ink.secondary : stream.tint,delay:0.08,settled:captureSettled,pace:!stale && store.prefs.showPaceGuide ? PaceGuide.remaining(w) : nil)}
        }.padding(.leading,27)
    }
    @ViewBuilder private func horizon(_ stream: Stream,reading: Reading,short: Bool) -> some View {
        if let window = WindowLogic.selected(reading.windows,choice:short ? stream.hoverPrimary : stream.hoverSecondary,fallback:short ? (store.prefs.singleColumn ? "auto" : "short") : "long"), let remaining = WindowLogic.remaining(window) {
            let expired = WindowLogic.expired(window,snapshot:reading.snapshot)
            let stale = reading.stale(minutes:store.prefs.refreshMinutes) || expired
            let warning = stream.warns && !stream.ignoredWindows.contains(window.id) && remaining <= store.prefs.threshold && !stale
            let runOut = stale || !store.prefs.showRunOut ? nil : RunOut.date(window)
            VStack(alignment:.leading,spacing:MeterLayout.textGap) {
                HStack(alignment:.firstTextBaseline,spacing:5) {
                    Text("\(Int(remaining.rounded()))").font(.system(size:16,weight:.semibold)).monospacedDigit()
                    Text("%").font(.system(size:10)).foregroundStyle(Ink.secondary)
                    if store.prefs.showWindowNames {Text([WindowLogic.label(window),window.scope].compactMap{$0}.joined(separator:" · ")).font(.system(size:9)).foregroundStyle(Ink.secondary).lineLimit(1)}
                    if expired { Image(systemName:"clock").font(.system(size:9)).foregroundStyle(Ink.amber) }
                    Spacer(minLength:0)
                }.foregroundStyle(warning ? (remaining <= 5 ? Ink.red : Ink.amber) : Ink.text)
                QuotaMeter(value:remaining,tint:stale ? Ink.secondary.opacity(0.55) : stream.tint,delay:Double(store.visible.firstIndex(where:{$0.id == stream.id}) ?? 0)*0.02+(short ? 0.05 : 0.1),settled:captureSettled,pace:!stale && store.prefs.showPaceGuide ? PaceGuide.remaining(window) : nil)
                if !store.prefs.compact && (store.prefs.showResets || runOut != nil) {
                    // The reset time keeps its full text; the forecast takes what is left.
                    HStack(spacing:4) {
                        if store.prefs.showResets {
                            Text(expired ? "리셋 전 기록" : WindowLogic.resetDisplay(window.resetsAt,style:store.prefs.resetStyle,todayTomorrow:store.prefs.resetTodayTomorrow,weekdays:store.prefs.resetWeekdays)).font(.system(size:9)).monospacedDigit().foregroundStyle(expired ? Ink.amber : Ink.secondary).lineLimit(1).fixedSize().layoutPriority(1)
                        }
                        if let runOut {
                            RunOutLabel(date:runOut,color:warnable(stream,window) ? Ink.amber : Ink.secondary).frame(maxWidth:.infinity,alignment:store.prefs.showResets ? .trailing : .leading)
                        }
                    }
                }
            }.help("잔여 \(String(format:"%.1f",remaining))% · \(WindowLogic.label(window))\n리셋: \(WindowLogic.exact(window.resetsAt))"+(runOut == nil ? "" : RunOut.help(window))+"\n확인: \(WindowLogic.exact(reading.snapshot?.fetchedAt))")
        } else {
            VStack(alignment:.leading,spacing:3) {
                Text("—").font(.system(size:16)).foregroundStyle(Ink.secondary)
                Text((short ? stream.hoverPrimary : stream.hoverSecondary) == "none" ? "표시 안 함" : reading.snapshot == nil ? (reading.loading ? "확인 중" : "연결 필요") : "해당 없음").font(.system(size:9)).foregroundStyle(Ink.secondary)
            }.frame(maxWidth:.infinity,alignment:.leading)
        }
    }
    private func detail(_ stream: Stream) -> some View {
        let reading = store.readings[stream.id] ?? Reading()
        let stale = reading.stale(minutes:store.prefs.refreshMinutes)
        return VStack(alignment:.leading,spacing:0) {
            Button {withAnimation(Motion.navigate){selection.account = nil}} label: {
                Label("전체 계정으로",systemImage:"chevron.left").font(.system(size:11,weight:.medium)).padding(.horizontal,10).frame(height:28).contentShape(Rectangle())
            }.buttonStyle(TeumTogglePressStyle()).accessibilityLabel("전체 계정으로 돌아가기").padding(.horizontal,36)
                .padding(.bottom,10) // keeps the detail content where it sat under the old header row
            ScrollView {
            VStack(alignment:.leading,spacing:18) {
                HStack(spacing:12) {
                    BrandMark(stream:stream,size:24)
                    VStack(alignment:.leading,spacing:5) {
                        Text(stream.name).font(.system(size:18,weight:.semibold))
                        Text([store.prefs.showAccount ? reading.snapshot?.account : nil,store.prefs.showPlan ? reading.snapshot?.planName : nil].compactMap{$0}.joined(separator:" · ")).font(.system(size:11)).foregroundStyle(Ink.secondary).textSelection(.enabled)
                    }
                }
                if let error = reading.error {
                    Label(error,systemImage:"exclamationmark.circle").font(.system(size:12)).foregroundStyle(Ink.amber).fixedSize(horizontal:false,vertical:true)
                }
                if stream.source == "agy" { Text("AGY 두 줄은 같은 계정의 서로 다른 모델 한도입니다.").font(.system(size:11)).foregroundStyle(Ink.secondary) }
                ForEach(reading.windows) { window in
                    VStack(alignment:.leading,spacing:8) {
                        HStack {
                            Text([WindowLogic.label(window),window.scope ?? window.label].compactMap{$0}.joined(separator:" · ")).font(.system(size:12,weight:.medium))
                            Spacer()
                            if let left = WindowLogic.remaining(window) { Text("\(String(format:"%.1f",left))% 남음").font(.system(size:13,weight:.semibold)).monospacedDigit() }
                            else if let credit = window.credit { Text(credit.amount).font(.system(size:12)) }
                        }
                        HStack {
                            Text("리셋 \(WindowLogic.exact(window.resetsAt))").font(.system(size:11)).foregroundStyle(Ink.secondary)
                            Spacer()
                            Toggle("경고",isOn:Binding(get:{ !stream.ignoredWindows.contains(window.id) },set:{value in
                                guard let i = store.prefs.streams.firstIndex(where:{$0.id == stream.id}) else { return }
                                store.prefs.streams[i].ignoredWindows.removeAll{$0 == window.id}
                                if !value { store.prefs.streams[i].ignoredWindows.append(window.id) }
                                store.save()
                            })).toggleStyle(TeumSwitch()).fixedSize().font(.system(size:11)).disabled(!stream.warns || window.extra)
                        }
                        if let detail = window.detail { Text(detail).font(.system(size:11)).foregroundStyle(Ink.secondary).textSelection(.enabled) }
                        if store.prefs.showRunOut,!stale,!WindowLogic.expired(window,snapshot:reading.snapshot),let forecast = RunOut.detail(window) {
                            Text(forecast.text).font(.system(size:11)).monospacedDigit().foregroundStyle(forecast.warning && warnable(stream,window) ? Ink.amber : Ink.secondary).fixedSize(horizontal:false,vertical:true)
                        }
                        if store.prefs.showPaceGuide,!stale,let pace = PaceGuide.remaining(window),let left = WindowLogic.remaining(window) {
                            QuotaMeter(value:left,tint:stream.tint,delay:0,settled:captureSettled,pace:pace)
                            Text(PaceGuide.text(pace)+" · 한 주기를 균등하게 쓰는 기준").font(.system(size:10)).foregroundStyle(Ink.secondary).padding(.top,2)
                        }
                        Rectangle().fill(Ink.rule).frame(height:1)
                    }
                }
                if let credits = reading.snapshot?.resetCredits,credits.isShown {ResetCreditsRow(credits:credits)}
                if store.prefs.showConsumption,let consumption = store.consumption(stream.id) { Text(consumption).font(.system(size:11)).foregroundStyle(Ink.secondary) }
                Text("마지막 확인 \(WindowLogic.exact(reading.snapshot?.fetchedAt))").font(.system(size:11)).foregroundStyle(Ink.secondary)
                if !stream.warns { Label("잔여량 부족·소진 경고에서 제외됩니다. 리셋 알림은 별도로 설정합니다.",systemImage:"bell.slash").font(.system(size:11)).foregroundStyle(Ink.secondary) }
                if stream.source == "claude" && reading.snapshot == nil {
                    Button("클로드 연결 허용") { Task { _ = await LocalCredentials.authorizeClaudeAccessAsync(); await store.refresh() } }.buttonStyle(TeumActionStyle())
                }
                if stream.source == "grok" && reading.snapshot == nil && !GrokDashboard.connected(directory:store.directory) {Button("Grok Bot 연결 허용") {Task{_ = await GrokBot.authorizeAsync();await store.refresh()}}.buttonStyle(TeumActionStyle())}
                Button("이 계정 설정 열기") {accountSettings(stream.id)}.buttonStyle(TeumActionStyle())
            }.padding(.horizontal,40).padding(.vertical,10)
            }.frame(maxHeight:.infinity)
        }
    }
}

struct NotchStrip: View {
    @ObservedObject var store: QuotaStore
    var notchWidth: CGFloat
    var height: CGFloat
    var open:(()->Void)? = nil
    var settings:(()->Void)? = nil
    var wings:(left:CGFloat,right:CGFloat) {NotchLayout.wings(store.prefs,count:store.pinned.count)}
    var wing:CGFloat {max(wings.left,wings.right)}
    var body: some View {
        let items = store.pinned
        let half = (items.count+1)/2
        return HStack(spacing:0) {
            if store.prefs.notchStyle == "mixed" {
                numbers(store.numberStreams).frame(width:wings.left)
            } else if store.prefs.notchStyle == "fourNumbers" {
                numbers(Array(store.numberStreams.prefix((store.numberStreams.count+1)/2))).frame(width:wings.left)
            } else if store.prefs.notchStyle == "compactNumbers" {
                numbers(Array(store.numberStreams.prefix(1))).frame(width:wings.left)
            } else if store.prefs.notchStyle == "allNumbers" {
                numbers(Array(items.prefix(half))).frame(width:wings.left)
            } else if store.prefs.notchStyle == "numbers" {
                if let stream = items.first,let r = store.readings[stream.id],let w = store.notchWindow(stream),let p = WindowLogic.remaining(w) {
                    let stale = r.stale(minutes:store.prefs.refreshMinutes) || WindowLogic.expired(w,snapshot:r.snapshot)
                    HStack(spacing:5) {
                        if wing >= 56 { Image(systemName:stale ? "clock" : stream.symbol).foregroundStyle(stale ? Ink.amber : stream.tint) }
                        Text("\(Int(p.rounded()))%").monospacedDigit().foregroundStyle(stale ? Ink.secondary : .white)
                    }.font(.system(size:11,weight:.medium)).frame(width:wing)
                    .help("\(stream.name) · \(stale ? "마지막 확인 값" : "현재 잔여량") \(Int(p.rounded()))% · 리셋 \(WindowLogic.exact(w.resetsAt))")
                } else { Image(systemName:"waveform.path").font(.system(size:12)).foregroundStyle(Ink.secondary).frame(width:wing) }
            } else { bars(Array(items.prefix(half))).frame(width:wings.left) }
            Color.black.frame(width:notchWidth)
            if store.prefs.notchStyle == "mixed" {
                bars(Array(items.dropFirst(2))).frame(width:wings.right)
            } else if store.prefs.notchStyle == "fourNumbers" {
                numbers(Array(store.numberStreams.dropFirst((store.numberStreams.count+1)/2))).frame(width:wings.right)
            } else if store.prefs.notchStyle == "compactNumbers" {
                numbers(Array(store.numberStreams.dropFirst().prefix(1))).frame(width:wings.right)
            } else if store.prefs.notchStyle == "allNumbers" {
                numbers(Array(items.suffix(items.count-half))).frame(width:wings.right)
            } else {bars(store.prefs.notchStyle == "numbers" ? items : Array(items.suffix(items.count-half))).frame(width:wings.right)}
        }.frame(height:height).background(.black).clipShape(UnevenRoundedRectangle(bottomLeadingRadius:9,bottomTrailingRadius:9))
        .contentShape(Rectangle()).onTapGesture {open?()}
        .contextMenu {
            Button("왼쪽 숫자 + 오른쪽 막대") {withAnimation(Motion.navigate){store.prefs.notchStyle = "mixed";store.save()}}
            Button("선택한 숫자 2개") {withAnimation(Motion.navigate){store.prefs.notchStyle = "compactNumbers";store.save()}}
            Button("숫자 4개로 표시") {withAnimation(Motion.navigate){store.prefs.notchStyle = "fourNumbers";store.save()}}
            Button("전체 숫자로 표시") {withAnimation(Motion.navigate){store.prefs.notchStyle = "allNumbers";store.save()}}
            Button("미니 막대로 표시") {withAnimation(Motion.navigate){store.prefs.notchStyle = "bars";store.save()}}
            if let settings {Divider();Button("설정 열기",action:settings)}

        }.modifier(NotchAccess(settings:settings))
    }
    private func numbers(_ streams:[Stream]) -> some View {
        HStack(spacing:6) {
            ForEach(streams) {s in
                let r = store.readings[s.id] ?? Reading()
                let window = store.notchWindow(s)
                let remaining = window.flatMap(WindowLogic.remaining)
                let stale = r.stale(minutes:store.prefs.refreshMinutes) || (window.map{WindowLogic.expired($0,snapshot:r.snapshot)} ?? false)
                HStack(spacing:3) {
                    BrandMark(stream:s,size:9)
                    Text(remaining.map{String(Int($0.rounded()))} ?? "—").font(.system(size:10,weight:.medium)).monospacedDigit().foregroundStyle(stale ? Ink.secondary : (window.map{store.warns(s,window:$0)} ?? false) ? Ink.amber : .white).lineLimit(1).fixedSize(horizontal:true,vertical:false)
                }.fixedSize().help("\(s.name) · \(stale ? "마지막 확인 값" : "잔여량") · \(remaining.map{String(format:"%.1f%%",$0)} ?? "미확인")")
            }
        }
    }
    private func bars(_ streams: [Stream]) -> some View {
        HStack(alignment:.center,spacing:max(0,min(4,(wing-12-CGFloat(streams.count)*5)/CGFloat(max(1,streams.count-1))))) {
            ForEach(streams) { s in
                let r = store.readings[s.id] ?? Reading()
                let w = store.notchWindow(s)
                let p = w.flatMap(WindowLogic.remaining)
                let stale = r.stale(minutes:store.prefs.refreshMinutes) || (w.map{WindowLogic.expired($0,snapshot:r.snapshot)} ?? false)
                let warn = w.map{store.warns(s,window:$0)} ?? false
                ZStack(alignment:.bottom) {
                    // The fill stays in the account colour so each bar is recognisable;
                    // a fresh warning tints the empty track instead.
                    Capsule().fill(warn && !stale ? Ink.amber.opacity(0.32) : Color.white.opacity(0.17))
                    if let p { Capsule().fill(stale ? Ink.secondary : s.tint).frame(height:12*p/100) }
                    else { Capsule().strokeBorder(Ink.secondary,lineWidth:0.8) }
                }.frame(width:5,height:12).help("\(s.name): \(p.map{String(Int($0.rounded()))+"% 남음"} ?? "연결 필요")"+(warn && !stale ? " · 잔여량 경고" : ""))
                .accessibilityLabel("\(s.name) \(p.map{String(Int($0.rounded()))+"퍼센트 남음"} ?? "연결 필요")"+(warn && !stale ? ", 잔여량 경고" : ""))
            }
        }
    }
}


struct QuotaMeter:View {
    var value:Double
    var tint:Color
    var delay:Double
    var settled:Bool
    var pace:Double? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body:some View {
        GeometryReader {geo in
            ZStack(alignment:.leading) {
                Capsule().fill(Color.white.opacity(0.10)).frame(height:MeterLayout.trackHeight)
                QuotaFill(value:value,tint:tint,delay:delay,animated:!settled && !reduceMotion).frame(width:geo.size.width,height:MeterLayout.trackHeight)
                if let pace {
                    RoundedRectangle(cornerRadius:0.75).fill(Ink.text.opacity(0.7)).frame(width:1.5,height:MeterLayout.guideHeight).offset(x:max(0,min(geo.size.width-1.5,geo.size.width*pace/100)))
                }
            }.frame(height:MeterLayout.guideHeight)
        }.frame(height:MeterLayout.guideHeight)
            .help(pace.map(PaceGuide.text) ?? "잔여 \(Int(value.rounded()))%")
            .animation(Motion.feedback,value:tint)
    }
}

private struct NotchAccess:ViewModifier {
    var settings:(()->Void)?
    @ViewBuilder func body(content:Content)->some View {
        if let settings {content.accessibilityAction(named:Text("설정 열기")){settings()}}
        else {content}
    }
}
