import AppKit
import SwiftUI
import Combine
import ServiceManagement
import UserNotifications
import QuotaCore
import QuotaModel

class InteractiveHost<Content:View>:NSHostingView<Content> {
    override func acceptsFirstMouse(for event:NSEvent?)->Bool {true}
}

final class HoverHost<Content:View>: InteractiveHost<Content> {
    var entered: (() -> Void)?
    var exited: (() -> Void)?
    private var area: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // inVisibleRect follows bounds changes itself. Replacing this area on
        // every SwiftUI layout can lose an entry while the pointer stays inside.
        guard area == nil else{return}
        let next = NSTrackingArea(rect:.zero,options:[.activeAlways,.inVisibleRect,.mouseEnteredAndExited,.mouseMoved],owner:self,userInfo:nil)
        addTrackingArea(next); area = next
    }
    override func mouseMoved(with event:NSEvent) { entered?() }
    override func mouseEntered(with event:NSEvent) { entered?() }
    override func mouseExited(with event:NSEvent) { exited?() }
}

final class FloatingPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender:Any?) { onEscape?() }
}

final class StatusHover: NSObject {
    var enter: (() -> Void)?
    var leave: (() -> Void)?
    @objc func mouseMoved(with event:NSEvent) { enter?() }
    @objc func mouseEntered(with event:NSEvent) { enter?() }
    @objc func mouseExited(with event:NSEvent) { leave?() }
}

@MainActor final class AppDelegate: NSObject,NSApplicationDelegate {
    let store:QuotaStore = {
        let args = CommandLine.arguments
        if args.contains("--page-render-test"),let i = args.firstIndex(of:"--live-data"),i+1<args.count {
            return QuotaStore(directory:URL(fileURLWithPath:args[i+1]),bootstrapLegacy:false)
        }
        return args.contains("--menu-bar-test") || args.contains("--hover-input-test") || args.contains("--history-chart-capture") || args.contains("--page-render-test") || args.contains("--meter-motion-test") || args.contains("--capture-policies") || args.contains("--render-readme") || args.contains("--ui-smoke") || args.contains("--island-motion-test") || args.contains("--notice-motion-test") ? QuotaStore.fixture() : QuotaStore()
    }()
    private var status: NSStatusItem!
    private let statusHover = StatusHover()
    private var strip: FloatingPanel?
    private var panel: FloatingPanel?
    private var settingsWindow: NSWindow?
    private var held = false
    private var fromNotch = true
    private let menuAnimator = MenuPanelAnimator()
    private var menuVisibility = 0.0
    private var menuOpen = false
    private var menuHoverSuppressed = false
    private var menuMotionSamples:[[String:Double]] = []
    private var openWork: DispatchWorkItem?
    private var hoverGeneration = 0
    // Only the offscreen motion harness supplies this; live input always uses AppKit.
    private var fixturePointer:NSPoint?
    private var closeWork: DispatchWorkItem?
    private var changes: AnyCancellable?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var warningIDs: Set<String> = []
    private var notificationsEnabled = false
    private var islandExpanded = false
    private var islandGeneration = 0
    private var noticeEngine = NoticeEngine()
    private var activeNotice:IslandNotice?
    private var noticeQueue:[IslandNotice] = []
    private var noticeCloseWork:DispatchWorkItem?
    private var notchScreen: NSScreen? { NSScreen.screens.first(where:{$0.safeAreaInsets.top > 0}) ?? NSScreen.screens.first }
    private var notch: (screen:NSScreen,width:CGFloat,height:CGFloat)? {
        guard let screen = notchScreen else {return nil}
        let width:CGFloat
        if let left = screen.auxiliaryTopLeftArea,let right = screen.auxiliaryTopRightArea {width = max(0,right.minX-left.maxX)}
        else {width = 0}
        return (screen,NotchLayout.cameraGap(store.prefs,detected:width),max(screen.safeAreaInsets.top,32))
    }
    func applicationDidFinishLaunching(_ notification:Notification) {
        if CommandLine.arguments.contains("--grok-direct-json") {
            NSApp.setActivationPolicy(.accessory)
            Task {
                if CommandLine.arguments.contains("--authorize-grok") {_ = await GrokBot.authorizeAsync()}
                let started = Date()
                var result:[String:Any] = ["source":"Grok Bot · 직접 API", "authorization":GrokBot.sessionDescription()]
                do {
                    let snapshot = try await GrokBot.dashboardUsage()
                    if CommandLine.arguments.contains("--connect-grok-direct") {try await GrokNative.activate(directory:store.directory)}
                    result["snapshot"] = try JSONSerialization.jsonObject(with:JSONEncoder().encode(snapshot))
                    result["ok"] = true
                } catch {
                    result["ok"] = false
                    result["error"] = Collector.message(error,source:"grok")
                }
                result["seconds"] = Date().timeIntervalSince(started)
                if let data = try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]) {print(String(decoding:data,as:UTF8.self))}
                fflush(stdout);NSApp.terminate(nil)
            };return
        }
        if let i = CommandLine.arguments.firstIndex(of:"--menu-bar-test"),i+1<CommandLine.arguments.count {runMenuBarTest(at:CommandLine.arguments[i+1]);return}
        if let i = CommandLine.arguments.firstIndex(of:"--hover-input-test"),i+1<CommandLine.arguments.count {runHoverInputTest(at:CommandLine.arguments[i+1]);return}
        if let i = CommandLine.arguments.firstIndex(of:"--history-chart-capture"),i+1<CommandLine.arguments.count {TokenChartCapture.run(at:CommandLine.arguments[i+1]);NSApp.terminate(nil);return}
        if let i = CommandLine.arguments.firstIndex(of:"--page-render-test"),i+1<CommandLine.arguments.count {runPageRenderTest(at:CommandLine.arguments[i+1]);return}
        if let i = CommandLine.arguments.firstIndex(of:"--meter-motion-test"),i+1<CommandLine.arguments.count {runMeterMotion(at:CommandLine.arguments[i+1]);return}
        if let i = CommandLine.arguments.firstIndex(of:"--capture-policies"),i+1<CommandLine.arguments.count {Capture.policies(at:CommandLine.arguments[i+1]);NSApp.terminate(nil);return}
        if let i = CommandLine.arguments.firstIndex(of:"--island-motion-test"),i+1 < CommandLine.arguments.count {runIslandMotion(at:CommandLine.arguments[i+1]);return}
        if let i = CommandLine.arguments.firstIndex(of:"--notice-motion-test"),i+1 < CommandLine.arguments.count {runIslandMotion(at:CommandLine.arguments[i+1],notice:true);return}
        if CommandLine.arguments.contains("--capacity-json") {
            // Read-only: estimate from this Mac's logs and print; nothing is saved.
            let began = Date()
            let tokens = (try? Data(contentsOf:store.directory.appendingPathComponent("token-history.json"))).flatMap{data -> TokenHistoryCache? in
                let decoder = JSONDecoder();decoder.dateDecodingStrategy = .secondsSince1970
                return try? decoder.decode(TokenHistoryCache.self,from:data)
            }
            let estimates = CapacityEstimator.estimate(streams:store.prefs.streams.filter{$0.connected != false},samples:store.capacity.samples,tokenCache:tokens,home:FileManager.default.homeDirectoryForCurrentUser,now:.now)
            let rows = estimates.mapValues {e in ["weightedTokensPerPercentagePoint":e.tokensPerPoint as Any? ?? NSNull(),"points":e.points,"windows":e.windows,"method":e.method,"note":e.note as Any? ?? NSNull(),"summary":e.summary] as [String:Any]}
            let output:[String:Any] = ["seconds":Date().timeIntervalSince(began),"weighting":WorkTokens.formula,"estimates":rows]
            if let data = try? JSONSerialization.data(withJSONObject:output,options:[.prettyPrinted,.sortedKeys]) {print(String(decoding:data,as:UTF8.self))}
            fflush(stdout);NSApp.terminate(nil);return
        }
        if CommandLine.arguments.contains("--plan-json") {
            let source:QuotaStore
            if let i = CommandLine.arguments.firstIndex(of:"--plan-data"),i+1<CommandLine.arguments.count {source = QuotaStore(directory:URL(fileURLWithPath:CommandLine.arguments[i+1]),bootstrapLegacy:false)} else {source = store}
            let plan = source.currentPlan
            var output = QuotaPlanner.json(plan)
            output["preferredStreams"] = source.prefs.planPriority
            output["capacity"] = source.capacity.estimates.mapValues {e in ["weightedTokensPerPercentagePoint":e.tokensPerPoint as Any? ?? NSNull(),"observedPercentagePoints":e.points,"weeklyWindows":e.windows,"method":e.method,"note":e.note as Any? ?? NSNull(),"measuredAt":ISO8601DateFormatter().string(from:e.measuredAt)] as [String:Any]}
            output["capacityWeighting"] = WorkTokens.formula
            if let today = source.dailyGoals.today {
                output["todayGoals"] = ["observedSince":ISO8601DateFormatter().string(from:today.startedAt),"targetsPercentagePoints":today.targets,"observedUsedPercentagePoints":today.used,"remainingPercentagePoints":source.dailyGoals.remaining,"measurement":"observed quota decreases only; may omit usage hidden by resets or before first observation"]
            }
            if let data = try? JSONSerialization.data(withJSONObject:output,options:[.prettyPrinted,.sortedKeys]) {print(String(decoding:data,as:UTF8.self))}
            fflush(stdout);NSApp.terminate(nil);return
        }
        if CommandLine.arguments.contains("--token-stats-json") {
            Task {
                await store.tokenHistory.load(streams:store.prefs.streams,force:true)
                if CommandLine.arguments.contains("--token-quarter") {store.tokenHistory.period = .quarter}
                let report = store.tokenHistory.report()
                let result:[String:Any] = ["tokens":report.total.allTokens,"input":report.total.input,"output":report.total.output,"cacheRead":report.total.cacheRead,"cacheWrite":report.total.cacheWrite,"models":report.models.map{["source":$0.source.rawValue,"model":$0.model,"tokens":$0.entry.allTokens] as [String:Any]},"days":report.daily.count,"projects":report.projects.count,"sessions":report.sessions,"roots":store.tokenHistory.cache.roots,"error":store.tokenHistory.error ?? ""]
                if let i = CommandLine.arguments.firstIndex(of:"--token-capture"),i+1<CommandLine.arguments.count {
                    store.panelPage = 1
                    Capture.render(QuotaPanel(store:store,held:true,toggleHold:{},settings:{},close:{},initialPage:1,embedded:true,cameraGap:196),width:store.prefs.panelWidth,to:URL(fileURLWithPath:CommandLine.arguments[i+1]))
                }
                if let data = try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]) {print(String(decoding:data,as:UTF8.self))}
                fflush(stdout);NSApp.terminate(nil)
            };return
        }
        if CommandLine.arguments.contains("--collect-json") {
            Task {await CLICollector.run();NSApp.terminate(nil)};return
        }
        if CommandLine.arguments.contains("--ui-smoke") {runSmoke();NSApp.terminate(nil);return}
        if let i = CommandLine.arguments.firstIndex(of:"--refinement-capture"),i+1 < CommandLine.arguments.count {
            Capture.refinements(at:CommandLine.arguments[i+1]);NSApp.terminate(nil);return
        }
        if let i = CommandLine.arguments.firstIndex(of:"--render-readme"),i+1 < CommandLine.arguments.count {
            Capture.renderReadmeScreenshots(into:URL(fileURLWithPath:CommandLine.arguments[i+1]));NSApp.terminate(nil);return
        }
        if let i = CommandLine.arguments.firstIndex(of:"--capture"),i+1 < CommandLine.arguments.count {
            Capture.run(at:CommandLine.arguments[i+1]);NSApp.terminate(nil);return
        }
        if CommandLine.arguments.contains("--self-test") {
            let ok = SelfTest.run();fflush(stdout);exit(ok ? 0 : 1)
        }
        if CommandLine.arguments.contains("--probe") {
            Task { await store.refresh();Probe.write(store);NSApp.terminate(nil) };return
        }
        NSApp.setActivationPolicy(.accessory)
        notificationsEnabled = store.prefs.notifications
        setupStatusItem()
        changes = store.$prefs.debounce(for:.milliseconds(100),scheduler:RunLoop.main).sink {[weak self] prefs in
            guard let self else{return}
            if prefs.notifications && !self.notificationsEnabled {
                UNUserNotificationCenter.current().requestAuthorization(options:[.alert,.sound]) {granted,_ in
                    if !granted {Task{@MainActor in self.store.saveError = "알림이 꺼져 있어요. 시스템 설정 → 알림에서 Teum을 허용해 주세요."}}
                }
            }
            self.notificationsEnabled = prefs.notifications
            self.noticeQueue.removeAll{!self.noticeAllowed($0)}
            if let notice = self.activeNotice,!self.noticeAllowed(notice) {self.hidePanel()}
            self.updateStrip();self.resizePanel();self.updateStatus();self.store.save()
        }
        noticeEngine = NoticeEngine(previous:store.readings.compactMapValues(\.snapshot))
        store.didRefresh = {[weak self] in
            guard let self else{return}
            self.updateStatus();self.notifyWarnings()
            self.queueNotices(self.noticeEngine.events(prefs:self.store.prefs,readings:self.store.readings,goals:self.store.dailyGoals.today))
        }
        store.previewNotice = {[weak self] notice in self?.queueNotices([notice])}
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown]) {[weak self] _ in
            Task { @MainActor in self?.outsideClick() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching:[.keyDown,.leftMouseDown]) {[weak self] event in
            if event.type == .keyDown && event.keyCode == 53 {self?.hidePanel();return nil}
            return event
        }
        NotificationCenter.default.addObserver(self,selector:#selector(screenChanged),name:NSApplication.didChangeScreenParametersNotification,object:nil)
        NSWorkspace.shared.notificationCenter.addObserver(self,selector:#selector(woke),name:NSWorkspace.didWakeNotification,object:nil)
        updateStrip();store.schedule()
        Task {await store.refresh()}
    }
    private func setupStatusItem() {
        status = NSStatusBar.system.statusItem(withLength:28)
        if let b = status.button {
            b.imagePosition = .imageLeading
            b.font = .monospacedDigitSystemFont(ofSize:11,weight:.medium)
            b.target = self;b.action = #selector(statusClicked);b.sendAction(on:[.leftMouseUp,.rightMouseUp])
            b.toolTip = "Teum · AI 계정의 남은 사용량"
            let area = NSTrackingArea(rect:.zero,options:[.activeAlways,.inVisibleRect,.mouseEnteredAndExited,.mouseMoved],owner:statusHover,userInfo:nil)
            b.addTrackingArea(area)
        }
        statusHover.enter = {[weak self] in self?.queueOpen(notch:false)}
        statusHover.leave = {[weak self] in
            guard let self else{return}
            if !self.hoverSourceContains(self.pointer,notch:false) {self.menuHoverSuppressed = false}
            self.queueClose()
        }
        updateStatus()
    }
    @objc private func screenChanged() {updateStrip();if panel?.isVisible == true {positionPanel()}}
    @objc private func woke() {Task{await store.refresh()}}
    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle:"설정…",action:#selector(showSettings),keyEquivalent:",").target = self
            menu.addItem(withTitle:"새로고침",action:#selector(refreshNow),keyEquivalent:"r").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle:"Teum 종료",action:#selector(quit),keyEquivalent:"q").target = self
            status.menu = menu;status.button?.performClick(nil);status.menu = nil
            return
        }
        if menuOpen || islandExpanded {
            menuHoverSuppressed = true;hidePanel()
        }
        else {openWork?.cancel();held = true;showPanel(notch:false)}
    }
    @objc private func refreshNow() {Task{await store.refresh()}}
    @objc private func quit() {NSApp.terminate(nil)}
    private var pointer:NSPoint {fixturePointer ?? NSEvent.mouseLocation}
    private func surfaceContains(_ point:NSPoint,in window:FloatingPanel?)->Bool {
        guard let window,window.isVisible else{return false}
        if let content = window.contentView as? IslandContainer {
            let local = content.convert(window.convertPoint(fromScreen:point),from:nil)
            return content.exportPath?.contains(local) == true
        }
        return window.frame.contains(point)
    }
    private func hoverSourceContains(_ point:NSPoint,notch:Bool)->Bool {
        if notch {
            guard store.prefs.notchEnabled,strip?.isVisible == true else{return false}
            if activeNotice != nil {return surfaceContains(point,in:strip)}
            guard let n = self.notch else{return false}
            let wings = NotchLayout.wings(store.prefs,count:store.pinned.count)
            return collapsedFrame(width:n.width+wings.left+wings.right,height:n.height,screen:n.screen).contains(point)
        }
        guard let button = status?.button,let window = button.window else{return false}
        return window.convertToScreen(button.convert(button.bounds,to:nil)).contains(point)
    }
    private func cancelHoverOpen() {hoverGeneration += 1;openWork?.cancel();openWork = nil}
    private func queueOpen(notch:Bool) {
        // A tracking-area replacement can emit mouseEntered long after the cursor
        // left. Never use that event alone as proof of current hover intent.
        guard hoverSourceContains(pointer,notch:notch),notch || !menuHoverSuppressed else{return}
        closeWork?.cancel()
        if activeNotice != nil {showPanel(notch:notch);return}
        if islandExpanded || (panel?.isVisible == true && panel !== strip && menuOpen) {return}
        // Moves recover a missed entry, but must not restart the hover delay.
        guard openWork == nil else{return}
        cancelHoverOpen();let generation = hoverGeneration
        let work = DispatchWorkItem {[weak self] in
            guard let self,self.hoverGeneration == generation else{return}
            self.openWork = nil
            guard self.hoverSourceContains(self.pointer,notch:notch) else{return}
            self.showPanel(notch:notch)
        }
        openWork = work;DispatchQueue.main.asyncAfter(deadline:.now()+store.prefs.hoverDelay,execute:work)
    }
    private func queueClose() {
        // Tracking owners can deliver a late exit after layout/replacement.
        // Position is the authority, before cancelling a valid pending open.
        let point = pointer
        if surfaceContains(point,in:panel) || surfaceContains(point,in:strip) || hoverSourceContains(point,notch:false) {closeWork?.cancel();return}
        cancelHoverOpen();closeWork?.cancel()
        guard !held,store.panelInteractions == 0 else{return}
        let work = DispatchWorkItem {[weak self] in
            guard let self,!self.held,self.store.panelInteractions == 0 else{return}
            let point = self.pointer
            if self.surfaceContains(point,in:self.panel) || self.surfaceContains(point,in:self.strip) || self.hoverSourceContains(point,notch:false) {return}
            self.hidePanel()
        }
        closeWork = work;DispatchQueue.main.asyncAfter(deadline:.now()+store.prefs.closeDelay,execute:work)
    }
    private func configure(_ p:FloatingPanel) {
        p.isOpaque = false;p.backgroundColor = .clear;p.hasShadow = false;p.hidesOnDeactivate = false;p.acceptsMouseMovedEvents = true;p.isMovable = false
        p.level = .statusBar;p.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.stationary]
        p.isReleasedWhenClosed = false;p.animationBehavior = .none
    }
    private func updateStrip(recoverHover:Bool = true) {
        guard store.prefs.notchEnabled,let n = notch else{strip?.orderOut(nil);return}
        if islandExpanded || (panel === strip && strip?.contentView is IslandContainer) {return}
        let width = n.width + NotchLayout.wings(store.prefs,count:store.pinned.count).left+NotchLayout.wings(store.prefs,count:store.pinned.count).right
        let frame = collapsedFrame(width:width,height:n.height,screen:n.screen)
        if strip == nil {
            let p = FloatingPanel(contentRect:frame,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false);configure(p);strip = p
        }
        let host = HoverHost(rootView:NotchStrip(store:store,notchWidth:n.width,height:n.height,open:{[weak self] in guard let self else{return};self.held = true;self.showPanel(notch:true)},settings:{[weak self] in self?.showSettings()}))
        host.entered = {[weak self,weak host] in guard let self,self.strip?.contentView === host else{return};self.queueOpen(notch:true)}
        host.exited = {[weak self,weak host] in guard let self,self.strip?.contentView === host else{return};self.queueClose()}
        host.sizingOptions = [];host.frame = NSRect(origin:.zero,size:frame.size)
        CATransaction.begin();CATransaction.setDisableActions(true)
        strip?.contentView = host;strip?.setFrame(frame,display:false)
        host.layoutSubtreeIfNeeded();host.updateTrackingAreas();host.displayIfNeeded()
        CATransaction.commit();strip?.orderFrontRegardless()
        // A replacement appearing under a stationary cursor has no boundary
        // crossing to generate mouseEntered. Reconcile from the actual point.
        if recoverHover,hoverSourceContains(pointer,notch:true) {queueOpen(notch:true)}
    }
    private func collapsedFrame(width:CGFloat,height:CGFloat,screen:NSScreen) -> NSRect {
        if CommandLine.arguments.contains("--menu-bar-test") || CommandLine.arguments.contains("--hover-input-test") || CommandLine.arguments.contains("--page-render-test") || CommandLine.arguments.contains("--island-motion-test") || CommandLine.arguments.contains("--notice-motion-test") {return NSRect(x:-20000-width/2,y:-20000-height,width:width,height:height)}
        let wings = NotchLayout.wings(store.prefs,count:store.pinned.count)
        return NSRect(x:screen.frame.midX-width/2+(wings.right-wings.left)/2,y:screen.frame.maxY-height,width:width,height:height)
    }
    private func showPanel(notch:Bool) {
        cancelHoverOpen()
        if !islandExpanded {store.panelPage = 0}
        closeWork?.cancel()
        let noticeSize = activeNotice != nil ? (strip?.contentView as? IslandContainer)?.presentedBounds.size : nil
        let upgradingNotice = activeNotice != nil
        activeNotice = nil;noticeCloseWork?.cancel()
        if notch,store.prefs.notchEnabled,let n = self.notch {
            menuAnimator.stop();menuOpen = false;menuVisibility = 0
            if strip == nil {updateStrip()}
            guard let island = strip else{return}
            if let panel,panel !== island {panel.orderOut(nil)}
            let continuing = upgradingNotice ? nil : island.contentView as? IslandContainer
            panel = island;fromNotch = true;islandExpanded = true;islandGeneration += 1
            if let continuing {continuing.transition(opening:true)}
            else {
                replacePanelContent()
                if let content = island.contentView as? IslandContainer {
                    content.prepareCollapsed(from:noticeSize);content.transition(opening:true)
                }
            }
            island.hasShadow = false;island.orderFrontRegardless()
            _ = n
            return
        }
        // A menu-bar click stays anchored here even when the notch is enabled.
        if panel === strip,strip != nil {
            islandGeneration += 1;islandExpanded = false;panel = nil
            updateStrip(recoverHover:false)
        }
        fromNotch = false
        if panel == nil {
            let p = FloatingPanel(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false);configure(p)
            p.hasShadow = true;p.onEscape = {[weak self] in self?.hidePanel()};panel = p
        }
        replacePanelContent();positionPanel()
        animateMenu(open:true)
    }
    private func animateMenu(open:Bool) {
        guard let panel,panel !== strip else{return}
        menuOpen = open;panel.ignoresMouseEvents = !open
        if open {panel.alphaValue = menuVisibility;panel.orderFrontRegardless()}
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || CommandLine.arguments.contains("--ui-smoke")
        menuAnimator.animate(from:menuVisibility,to:open ? 1 : 0,duration:reduced ? 0 : open ? 0.20 : 0.14) { [weak self,weak panel] value in
            guard let self,let panel,self.panel === panel else{return}
            self.menuVisibility = value;panel.alphaValue = value;self.positionPanel()
            if CommandLine.arguments.contains("--menu-bar-test") {
                self.menuMotionSamples.append(["open":open ? 1 : 0,"progress":value,"alpha":panel.alphaValue,"y":panel.frame.minY,"time":ProcessInfo.processInfo.systemUptime])
            }
        } completion: { [weak self,weak panel] in
            guard let self,let panel,self.panel === panel,!self.menuOpen else{return}
            panel.orderOut(nil);panel.ignoresMouseEvents = false;self.panel = nil
            self.displayNextNotice()
        }
    }
    private func replacePanelContent() {
        guard let panel else{return}
        let root = QuotaPanel(store:store,held:held,toggleHold:{[weak self] in guard let self else{return};self.held.toggle()},settings:{[weak self] in self?.showSettings()},close:{[weak self] in self?.hidePanel()},embedded:islandExpanded,cameraGap:islandExpanded ? notch?.width ?? 196 : 0,accountSettings:{[weak self] id in self?.showAccountSettings(id)},planSettings:{[weak self] in self?.openSettings(tab:6)})
        if islandExpanded,let n = notch {
            let header = NSHostingView(rootView:NotchStrip(store:store,notchWidth:n.width,height:n.height));header.sizingOptions = []
            let detail:NSView
            let bodyHeight:CGFloat
            let contentWidth:CGFloat
            if let notice = activeNotice {
                let host = NSHostingView(rootView:IslandNoticeView(notice:notice));host.sizingOptions = [];detail = host
                bodyHeight = 80;contentWidth = max(440,n.width+NotchLayout.wings(store.prefs,count:store.pinned.count).left+NotchLayout.wings(store.prefs,count:store.pinned.count).right+24)
            } else {
                let host = InteractiveHost(rootView:root);host.sizingOptions = [];detail = host
                bodyHeight = store.panelHeight;contentWidth = store.prefs.panelWidth
            }
            let collapsedWidth = n.width+NotchLayout.wings(store.prefs,count:store.pinned.count).left+NotchLayout.wings(store.prefs,count:store.pinned.count).right
            let width = max(contentWidth,collapsedWidth+24)
            let content = IslandContainer(header:header,detail:detail,width:width,headerSize:NSSize(width:collapsedWidth,height:n.height),headerOffset:(NotchLayout.wings(store.prefs,count:store.pinned.count).right-NotchLayout.wings(store.prefs,count:store.pinned.count).left)/2,detailSize:NSSize(width:contentWidth,height:bodyHeight),keepsCompactHeader:activeNotice != nil)
            content.entered = {[weak self,weak content] in
                guard let self,self.panel?.contentView === content else{return}
                if self.activeNotice != nil {self.queueOpen(notch:true)}
                else if !self.islandExpanded {self.queueOpen(notch:true)}
                else if self.surfaceContains(self.pointer,in:self.panel) {self.closeWork?.cancel()}
            };content.exited = {[weak self,weak content] in guard let self,self.panel?.contentView === content else{return};self.queueClose()}
            panel.contentView = content;resizePanel();return
        }
        let host = HoverHost(rootView:root)
        host.entered = {[weak self] in self?.closeWork?.cancel()}
        host.exited = {[weak self] in self?.queueClose()}
        host.frame.size = NSSize(width:store.prefs.panelWidth,height:host.fittingSize.height)
        panel.contentView = host;resizePanel()
    }
    private func resizePanel() {
        guard let panel,let host = panel.contentView else{return}
        let height = host.fittingSize.height
        var frame = panel.frame;frame.size = NSSize(width:host.fittingSize.width,height:height)
        panel.setFrame(frame,display:true);positionPanel()
    }
    private func positionPanel() {
        guard let panel,let screen = notchScreen else{return}
        if fromNotch && islandExpanded {
            if CommandLine.arguments.contains("--hover-input-test") || CommandLine.arguments.contains("--page-render-test") || CommandLine.arguments.contains("--island-motion-test") || CommandLine.arguments.contains("--notice-motion-test") {panel.setFrameOrigin(NSPoint(x:-20000-panel.frame.width/2,y:-20000-panel.frame.height))}
            else {panel.setFrameOrigin(NSPoint(x:screen.frame.midX-panel.frame.width/2,y:screen.frame.maxY-panel.frame.height))}
            return
        }
        if CommandLine.arguments.contains("--ui-smoke") || CommandLine.arguments.contains("--menu-bar-test") {panel.setFrameOrigin(NSPoint(x:-20000,y:-20000+(1-menuVisibility)*6));return}
        var x = screen.frame.midX-panel.frame.width/2
        var y = screen.frame.maxY - max(screen.safeAreaInsets.top,24) - panel.frame.height - 5
        var bounds = screen.visibleFrame
        if !fromNotch,let w = status?.button?.window {
            let sf = w.convertToScreen(status.button!.convert(status.button!.bounds,to:nil))
            let target = NSScreen.screens.first(where:{$0.frame.intersects(sf)}) ?? screen
            bounds = target.visibleFrame
            x = min(target.visibleFrame.maxX-panel.frame.width-8,max(target.visibleFrame.minX+8,sf.midX-panel.frame.width/2))
            y = min(sf.minY,bounds.maxY)-panel.frame.height-8
        }
        panel.setFrameOrigin(NSPoint(x:x,y:max(bounds.minY+6,y)+(fromNotch ? 0 : (1-menuVisibility)*6)))
    }
    private func outsideClick() {
        guard panel?.isVisible == true else{return}
        let point = pointer
        // The status button owns its mouse-up toggle. Closing on its earlier
        // global mouse-down would make that toggle reopen the same panel.
        if hoverSourceContains(point,notch:false) {return}
        if !surfaceContains(point,in:panel) && !surfaceContains(point,in:strip) {hidePanel()}
    }
    private func hidePanel() {
        cancelHoverOpen();closeWork?.cancel();noticeCloseWork?.cancel();activeNotice = nil;held = false
        guard islandExpanded,let island = strip,panel === island,let n = notch else{
            if menuOpen {animateMenu(open:false)}
            return
        }
        islandExpanded = false;islandGeneration += 1;let generation = islandGeneration
        let width = n.width+NotchLayout.wings(store.prefs,count:store.pinned.count).left+NotchLayout.wings(store.prefs,count:store.pinned.count).right
        let target = collapsedFrame(width:width,height:n.height,screen:n.screen)
        let finish = {[weak self] in guard let self,self.islandGeneration == generation,!self.islandExpanded else{return};self.panel = nil;self.strip?.hasShadow = false;self.updateStrip(recoverHover:false);self.displayNextNotice()}
        if let content = island.contentView as? IslandContainer {
            content.transition(opening:false) {finish()}
        } else {island.setFrame(target,display:true);finish()}
    }
    @objc private func showSettings() {openSettings(tab:1)}
    private func showAccountSettings(_ id:String) {openSettings(tab:0,account:id)}
    private func openSettings(tab:Int,account:String? = nil) {
        hidePanel()
        if settingsWindow == nil {
            let w = NSWindow(contentRect:NSRect(x:0,y:0,width:880,height:680),styleMask:[.titled,.closable,.miniaturizable,.fullSizeContentView],backing:.buffered,defer:false)
            w.title = "Teum 설정";w.titleVisibility = .hidden;w.titlebarAppearsTransparent = true;w.isReleasedWhenClosed = false;w.appearance = NSAppearance(named:.darkAqua)
            w.setFrame(NSRect(x:0,y:0,width:880,height:680),display:false);w.isMovableByWindowBackground = true
            w.center();settingsWindow = w
        }
        if let w = settingsWindow {
            let host = NSHostingView(rootView:SettingsView(store:store,loginChanged:{[weak self] enabled in self?.setLogin(enabled)},quit:{NSApp.terminate(nil)},initialTab:tab,initialAccount:account))
            host.sizingOptions = [];host.frame = NSRect(x:0,y:0,width:880,height:680)
            w.contentView = host
            var frame = w.frame;frame.size = NSSize(width:880,height:680);w.setFrame(frame,display:false)
            host.layoutSubtreeIfNeeded()
            if !w.isVisible {w.alphaValue = 0}
            w.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
            NSAnimationContext.runAnimationGroup {ctx in ctx.duration = 0.16;w.animator().alphaValue = 1}
        }
    }
    private func setLogin(_ enabled:Bool) {
        do {
            if enabled {try SMAppService.mainApp.register()}else{try SMAppService.mainApp.unregister()}
            store.prefs.launchAtLogin = enabled;store.save()
        } catch {store.saveError = "로그인 실행을 바꾸지 못했어요. 시스템 설정의 로그인 항목을 확인해 주세요."}
    }
    private func updateStatus() {
        guard let button = status?.button else{return}
        let summary = MenuBarUsage(store:store)
        button.image = summary.image
        button.title = ""
        button.toolTip = summary.help
        button.setAccessibilityLabel(summary.help)
    }
    private func noticeAllowed(_ notice:IslandNotice)->Bool {
        if notice.windowID == "preview" {return true}
        guard store.prefs.islandNotices,let s = store.prefs.streams.first(where:{$0.id == notice.stream.id}),s.visible,!s.ignoredWindows.contains(notice.windowID) else{return false}
        switch notice.kind {
        case .reset,.recovery:return store.prefs.resetNotices && s.notifyReset != false
        case .low,.empty:return store.prefs.lowNotices && s.warns && s.notifyLow != false
        case .pace:return store.prefs.paceNotices && s.warns && s.notifyLow != false
        case .goalNear:return store.prefs.goalNearNotices && s.warns && s.notifyLow != false
        case .goalReached:return store.prefs.goalReachedNotices && s.warns && s.notifyLow != false
        }
    }
    private func queueNotices(_ notices:[IslandNotice]) {
        guard store.prefs.notchEnabled else{return}
        noticeQueue.append(contentsOf:notices.filter{noticeAllowed($0)});noticeQueue = Array(noticeQueue.suffix(6));displayNextNotice()
    }
    private func displayNextNotice() {
        guard !islandExpanded,panel?.isVisible != true,activeNotice == nil,!noticeQueue.isEmpty,store.prefs.notchEnabled else{return}
        if strip == nil {updateStrip()}
        guard let island = strip else{return}
        activeNotice = noticeQueue.removeFirst();panel = island;fromNotch = true;islandExpanded = true;islandGeneration += 1
        replacePanelContent()
        if let content = island.contentView as? IslandContainer {content.prepareCollapsed();content.transition(opening:true)}
        island.orderFrontRegardless()
        let work = DispatchWorkItem {[weak self] in guard let self,self.activeNotice != nil else{return};self.hidePanel()}
        noticeCloseWork = work;DispatchQueue.main.asyncAfter(deadline:.now()+store.prefs.noticeSeconds,execute:work)
    }
    private func notifyWarnings() {
        let current = Set(store.warningStreams.map(\.id))
        let new = current.subtracting(warningIDs)
        warningIDs = current
        guard store.prefs.notifications,!new.isEmpty else{return}
        UNUserNotificationCenter.current().getNotificationSettings {[weak self] settings in
            guard settings.authorizationStatus == .authorized else{return}
            Task { @MainActor in
                guard let self else{return}
                let content = UNMutableNotificationContent();content.title = "AI 잔여량 확인"
                content.body = self.store.prefs.streams.filter{new.contains($0.id)}.map(\.name).joined(separator:", ")+" 잔여량이 \(Int(self.store.prefs.threshold))% 이하입니다."
                let request = UNNotificationRequest(identifier:"teum-low-"+UUID().uuidString,content:content,trigger:nil)
                try? await UNUserNotificationCenter.current().add(request)
            }
        }
    }
    private func runMenuBarTest(at path:String) {
        let out = URL(fileURLWithPath:path)
        try? FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        NSApp.setActivationPolicy(.accessory)
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        setupStatusItem();store.prefs.notchEnabled = true;updateStrip()
        var checks:[String:Bool] = [:]
        showPanel(notch:false)
        checks["menuSourceStaysBelowBarWithNotchEnabled"] = !fromNotch && !islandExpanded && panel !== strip
        checks["notchRemainsCompact"] = strip?.isVisible == true && !(strip?.contentView is IslandContainer)
        checks["nonactivating"] = panel?.styleMask.contains(.nonactivatingPanel) == true && panel?.isKeyWindow == false
        let first = MenuBarUsage(store:store)
        checks["firstConfiguredAccount"] = first.help.contains(store.prefs.streams[0].name) && first.text != "—"
        Capture.native(panel!.contentView!,to:out.appendingPathComponent("menu-panel.png"))
        func captureItem(_ name:String, remaining:Double? = nil, light:Bool = false) {
            let button = NSButton(title:status.button!.title,target:nil,action:nil)
            button.image = remaining.map{MenuBarUsage.icon(remaining:$0,stale:false)} ?? status.button!.image;button.imagePosition = .imageOnly
            button.font = .monospacedDigitSystemFont(ofSize:11,weight:.medium);button.isBordered = false
            button.frame = NSRect(x:0,y:0,width:28,height:24)
            let backdrop = NSView(frame:button.frame);backdrop.wantsLayer = true
            backdrop.appearance = NSAppearance(named:light ? .aqua : .darkAqua)
            backdrop.layer?.backgroundColor = NSColor(calibratedWhite:light ? 0.94 : 0.13,alpha:1).cgColor
            backdrop.addSubview(button)
            Capture.native(backdrop,to:out.appendingPathComponent(name))
        }
        captureItem("menu-item.png")
        captureItem("menu-item-100.png",remaining:100)
        captureItem("menu-item-zero.png",remaining:0)
        captureItem("menu-item-light.png",remaining:64,light:true)
        checks["compactTemplateIcon"] = status.length == 28 && status.button!.title.isEmpty && status.button!.image?.isTemplate == true
        store.prefs.streams.swapAt(0,1);updateStatus()
        checks["reorderingChangesMenuAccount"] = MenuBarUsage(store:store).help.contains(store.prefs.streams[0].name) && status.button!.toolTip == MenuBarUsage(store:store).help
        let saved = store.readings
        store.readings = [:];updateStatus()
        checks["unknownIsNotZero"] = MenuBarUsage(store:store).text == "—" && status.button!.title.isEmpty
        captureItem("menu-item-unknown.png")
        store.readings = saved;updateStatus()
        hidePanel();store.prefs.notchEnabled = false;updateStrip();showPanel(notch:false)
        checks["worksWithNotchDisabled"] = panel?.isVisible == true && strip?.isVisible == false && !fromNotch
        hidePanel();store.prefs.notchEnabled = true;updateStrip();showPanel(notch:true)
        checks["notchStillOpens"] = islandExpanded && panel === strip
        held = true;showPanel(notch:false)
        checks["clickCanSwitchFromNotchToMenu"] = !islandExpanded && panel !== strip && held
        hidePanel()
        // Use real menu anchor geometry with a fixture pointer, without moving the OS cursor.
        let button = status.button!, window = button.window!
        let anchor = window.convertToScreen(button.convert(button.bounds,to:nil))
        fixturePointer = NSPoint(x:anchor.midX,y:anchor.midY);store.prefs.hoverDelay = 0.03
        queueOpen(notch:false)
        func waitForOpen(_ attempt:Int = 0) {
            guard self.menuOpen,self.menuVisibility == 1 else {
                guard attempt < 150 else {print("FAIL: menu did not finish opening");fflush(stdout);exit(1)}
                DispatchQueue.main.asyncAfter(deadline:.now()+0.01) {waitForOpen(attempt+1)}
                return
            }
            checks["menuHoverOpensMenuSurface"] = self.panel?.isVisible == true && !self.fromNotch
            let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            checks["awakeOpeningProgress"] = reduced || self.menuMotionSamples.contains{$0["open"] == 1 && $0["progress"]! > 0 && $0["progress"]! < 1}
            // Use the current frame: macOS may reposition this temporary status item after layout.
            let currentButton = self.status.button!, currentWindow = currentButton.window!
            let clickAnchor = currentWindow.convertToScreen(currentButton.convert(currentButton.bounds,to:nil))
            self.fixturePointer = NSPoint(x:clickAnchor.midX,y:clickAnchor.midY)
            // macOS can deliver the global mouse-down before the status button's mouse-up action.
            self.outsideClick()
            checks["statusMouseDownKeepsPanelOpen"] = self.menuOpen
            checks["buttonActionDelivered"] = NSApp.sendAction(currentButton.action!,to:currentButton.target,from:currentButton)
            checks["clickClosesHoverPanel"] = !self.menuOpen && self.menuHoverSuppressed
            self.queueOpen(notch:false)
            checks["doesNotReopenUnderPointer"] = !self.menuOpen && self.openWork == nil
            checks["closingIgnoresMouse"] = reduced || self.panel?.ignoresMouseEvents == true
            self.fixturePointer = NSPoint(x:-30000,y:-30000);self.store.prefs.closeDelay = 0.03;self.statusHover.leave?()
            DispatchQueue.main.asyncAfter(deadline:.now()+0.25) {
                checks["leavingClosesUnpinnedPanel"] = self.panel == nil || self.panel?.isVisible == false
                checks["hoverReenabledAfterLeaving"] = !self.menuHoverSuppressed
                checks["closedProgress"] = self.menuVisibility == 0
                checks["awakeClosingProgress"] = reduced || self.menuMotionSamples.contains{$0["open"] == 0 && $0["progress"]! > 0 && $0["progress"]! < 1}
                checks["frontmostPreserved"] = front == NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                let samples = try! JSONSerialization.data(withJSONObject:self.menuMotionSamples,options:[.prettyPrinted,.sortedKeys])
                try? samples.write(to:out.appendingPathComponent("motion.json"))
                let data = try! JSONSerialization.data(withJSONObject:checks,options:[.prettyPrinted,.sortedKeys])
                try? data.write(to:out.appendingPathComponent("checks.json"))
                print(String(decoding:data,as:UTF8.self));fflush(stdout)
                NSStatusBar.system.removeStatusItem(self.status)
                exit(checks.values.contains(false) ? 1 : 0)
            }
        }
        waitForOpen()
    }
    private func runSmoke() {
        store.prefs.notchEnabled = false
        let before = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        showPanel(notch:true)
        var checks:[String:Bool] = [:]
        checks["panelShown"] = panel?.isVisible == true
        checks["firstClickAccepted"] = panel?.contentView?.acceptsFirstMouse(for:nil) == true
        checks["defaultSize"] = panel?.frame.size == NSSize(width:604,height:store.panelHeight)
        checks["nonactivating"] = panel?.styleMask.contains(.nonactivatingPanel) == true
        checks["doesNotTakeKeyboardFocus"] = panel?.isKeyWindow == false
        held = true;replacePanelContent()
        store.prefs.panelWidth = 560;store.prefs.compact = true;replacePanelContent()
        checks["compactResize"] = panel?.frame.size == NSSize(width:560,height:store.panelHeight)
        checks["frontmostPreserved"] = before == NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        hidePanel();checks["closeWorks"] = panel == nil || panel?.isVisible == false
        let data = try! JSONSerialization.data(withJSONObject:checks,options:[.prettyPrinted,.sortedKeys])
        print(String(data:data,encoding:.utf8)!);fflush(stdout)
        if checks.values.contains(false) {exit(1)}
    }
    private func runPageRenderTest(at path:String) {
        let out = URL(fileURLWithPath:path);try? FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        Task {
            if CommandLine.arguments.contains("--live-history-cache") {
                let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Teum/token-history.json")
                let loaded = await Task.detached(priority:.utility) {()->TokenHistoryCache? in
                    let decoder = JSONDecoder();decoder.dateDecodingStrategy = .secondsSince1970
                    return (try? Data(contentsOf:file)).flatMap{try? decoder.decode(TokenHistoryCache.self,from:$0)}
                }.value
                if let loaded {store.tokenHistory.cache = loaded}
            }
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            store.prefs.notchEnabled = true;held = true;updateStrip();showPanel(notch:true)
            let reduced = CommandLine.arguments.contains("--reduced-motion")
            if reduced {Self.find(PageStripView.self,in:strip?.contentView)?.reduceMotionOverride = true}
            let steps = [1,1,1,1,-1,-1,-1,-1]
            let capturePages = ProcessInfo.processInfo.environment["TEUM_PAGE_PNG"] != nil
            var requests:[Int] = []
            // Offset of a page's presented layer from its resting place, in page widths.
            @MainActor func offset(_ page:Int)->Double {
                guard let carousel = Self.find(PageStripView.self,in:self.strip?.contentView),let layer = carousel.pageView(page)?.layer,carousel.bounds.width>0 else{return .nan}
                return Double(((layer.presentation()?.position.x ?? layer.position.x)-layer.position.x)/carousel.bounds.width)
            }
            var mid:[Double] = [];var rest:[Double] = [];var visibleAtRest:[Bool] = []
            // Each step waits for the previous slide, so timer drift cannot overlap two steps.
            @MainActor func step(_ index:Int) {
                guard index<steps.count else{return}
                let delta = steps[index]
                let from = self.store.panelPage
                let target = PanelPages.next(from,by:delta);requests.append(target)
                SwipeTrace.record("test-page-requested",fields:["page":target])
                StallProbe.watch(["from":from,"to":target])
                self.store.navigation.go(to:target,step:delta)
                DispatchQueue.main.asyncAfter(deadline:.now()+0.09) {mid.append(offset(target))}
                DispatchQueue.main.asyncAfter(deadline:.now()+0.6) {
                    if index == 0,target == 1 {
                        click(148,80)
                        clicks["historyPeriodClick"] = self.store.tokenHistory.period == .month
                    }
                    rest.append(offset(target))
                    if let carousel = Self.find(PageStripView.self,in:self.strip?.contentView) {
                        visibleAtRest.append(carousel.mountedPages.allSatisfy{carousel.pageView($0)?.isHidden == ($0 != target)})
                    }
                    if capturePages,index<4,let view = self.strip?.contentView {Capture.native(view,to:out.appendingPathComponent("page-\(target).png"))}
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.05) {step(index+1)}
                }
            }
            // Real mouse events into the nested page hosts: open a row, go back,
            // and later pick a history period. Points are panel coordinates.
            var clicks:[String:Bool] = [:]
            @MainActor func click(_ x:CGFloat,_ y:CGFloat) {
                guard let island = self.strip?.contentView as? IslandContainer,let window = island.window else{return}
                let local = NSPoint(x:(island.bounds.width-island.detailSize.width)/2+x,y:y)
                let point = island.convert(local,to:nil)
                for type in [NSEvent.EventType.leftMouseDown,.leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1) {window.sendEvent(event)}
                }
            }
            DispatchQueue.main.asyncAfter(deadline:.now()+0.2) {
                click(120,119)
                // Wait for the detail's own slide-in to finish before pressing back.
                DispatchQueue.main.asyncAfter(deadline:.now()+0.5) {
                    clicks["rowOpensDetail"] = PanelSelection.latest?.account == self.store.visible.first?.id
                    click(86,76)
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.15) {clicks["backReturnsToTable"] = PanelSelection.latest?.account == nil}
                }
            }
            DispatchQueue.main.asyncAfter(deadline:.now()+1.2) {step(0)}
            DispatchQueue.main.asyncAfter(deadline:.now()+7.0) {
                if let view = self.strip?.contentView {Capture.native(view,to:out.appendingPathComponent("returned.png"))}
                SwipeTrace.flush()
                let carousel = Self.find(PageStripView.self,in:self.strip?.contentView)
                var checks = ["circularForward":Array(requests.prefix(4)) == [1,2,3,0],"circularBackward":Array(requests.suffix(4)) == [3,2,1,0],"returnedFirst":self.store.panelPage == 0,"focusPreserved":front == NSWorkspace.shared.frontmostApplication?.bundleIdentifier]
                // The incoming page is still travelling 90 ms in, from the side the step names.
                if reduced {checks["reducedMotionNoTravel"] = mid.count == steps.count && mid.allSatisfy{abs($0)<0.001}}
                else {checks["slideRunsOnCompositor"] = mid.count == steps.count && zip(mid,steps).allSatisfy{$0.0*Double($0.1)>0.05 && abs($0.0)<1.01}}
                checks["slideSettles"] = rest.count == steps.count && rest.allSatisfy{abs($0)<0.005}
                checks["onlyCurrentPageShown"] = visibleAtRest.count == steps.count && !visibleAtRest.contains(false)
                checks["allPagesMounted"] = carousel?.mountedPages.count == PanelPages.titles.count
                for name in ["rowOpensDetail","backReturnsToTable","historyPeriodClick"] {checks[name] = clicks[name] == true}
                try? JSONSerialization.data(withJSONObject:["checks":checks,"pages":requests,"midOffsets":mid,"restOffsets":rest],options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("result.json"))
                print(checks);self.hidePanel();NSApp.terminate(nil)
            }
        }
    }
    static func find<T:NSView>(_ type:T.Type,in view:NSView?)->T? {
        guard let view else{return nil}
        if let match = view as? T {return match}
        for child in view.subviews {if let match = find(type,in:child) {return match}}
        return nil
    }
    private func runMeterMotion(at path:String) {
        let out = URL(fileURLWithPath:path);try? FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        let reduced = CommandLine.arguments.contains("--reduced-motion")
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let window = FloatingPanel(contentRect:NSRect(x:-20000,y:-20000,width:360,height:70),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false);configure(window);panel = window
        let root = NSView(frame:NSRect(x:0,y:0,width:360,height:70));root.wantsLayer = true;root.layer?.backgroundColor = NSColor.black.cgColor
        let track = CALayer();track.frame = CGRect(x:20,y:30,width:320,height:3);track.backgroundColor = NSColor.darkGray.cgColor;track.cornerRadius = 1.5;root.layer?.addSublayer(track)
        let meter = QuotaFillView(frame:NSRect(x:20,y:30,width:320,height:3));root.addSubview(meter)
        window.contentView = root;window.orderFrontRegardless()
        meter.configure(value:80,color:.systemBlue,delay:0.08,animated:!reduced);meter.layoutSubtreeIfNeeded();CATransaction.flush()
        var frames:[[String:Double]] = [];let began = CACurrentMediaTime()
        func capture(_ name:String) {
            let image = NSImage(size:root.bounds.size);image.lockFocus()
            if let ctx = NSGraphicsContext.current?.cgContext { (root.layer?.presentation() ?? root.layer)?.render(in:ctx) }
            image.unlockFocus()
            if let data = image.tiffRepresentation,let rep = NSBitmapImageRep(data:data) {try? rep.representation(using:.png,properties:[:])?.write(to:out.appendingPathComponent(name))}
        }
        let timer = Timer(timeInterval:0.016,repeats:true) {_ in MainActor.assumeIsolated {
            let layer = meter.layer?.sublayers?.first
            frames.append(["t":CACurrentMediaTime()-began,"viewWidth":meter.bounds.width,"fillWidth":layer?.presentation()?.bounds.width ?? layer?.bounds.width ?? -1])
        }};RunLoop.main.add(timer,forMode:.common)
        DispatchQueue.main.asyncAfter(deadline:.now()+0.22) {capture("filling.png")}
        DispatchQueue.main.asyncAfter(deadline:.now()+0.9) {
            timer.invalidate();capture("filled.png")
            let widths = frames.compactMap{$0["fillWidth"]}
            let intermediate = widths.contains{$0>1 && $0<255}
            let checks = ["viewFrameUnchanged":frames.allSatisfy{$0["viewWidth"] == 320},"actualFillMotion":reduced ? !intermediate : intermediate,"targetReached":abs((widths.last ?? 0)-256)<1,"focusPreserved":front == NSWorkspace.shared.frontmostApplication?.bundleIdentifier]
            try? JSONSerialization.data(withJSONObject:["checks":checks,"frames":frames],options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("motion.json"))
            print(checks);window.orderOut(nil);NSApp.terminate(nil)
        }
    }
    private func runHoverInputTest(at path:String) {
        let out = URL(fileURLWithPath:path)
        try? FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        store.prefs.notchEnabled = true;store.prefs.hoverDelay = 0.06
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        updateStrip()
        let point = NSPoint(x:strip!.frame.midX,y:strip!.frame.midY)
        let outside = NSPoint(x:point.x,y:strip!.frame.minY-150)
        fixturePointer = point
        var checks:[String:Bool] = [:]
        // The old tracking owner's late exit must not cancel a valid entry.
        let original = strip!.contentView as! HoverHost<NotchStrip>
        original.entered?();original.exited?()
        DispatchQueue.main.asyncAfter(deadline:.now()+0.15) {
            checks["lateExitDoesNotCancelCurrentHover"] = self.islandExpanded
            self.hidePanel()
            DispatchQueue.main.asyncAfter(deadline:.now()+0.65) {
                self.fixturePointer = outside;self.queueClose();self.fixturePointer = point
                let host = self.strip!.contentView as! HoverHost<NotchStrip>
                let event = NSEvent.mouseEvent(with:.mouseMoved,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:self.strip!.windowNumber,context:nil,eventNumber:0,clickCount:0,pressure:0)!
                // Move delivery without mouseEntered reproduces a missed boundary.
                host.mouseMoved(with:event)
                let pending = self.openWork
                for _ in 0..<20 {host.mouseMoved(with:event)}
                checks["movesDoNotRestartDelay"] = self.openWork === pending
                DispatchQueue.main.asyncAfter(deadline:.now()+0.15) {
                    checks["moveRecoversMissingEnter"] = self.islandExpanded
                    self.hidePanel()
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.65) {
                        self.fixturePointer = outside;self.queueClose();self.fixturePointer = point;self.updateStrip()
                        DispatchQueue.main.asyncAfter(deadline:.now()+0.15) {
                            checks["replacementUnderPointerRecovers"] = self.islandExpanded
                            self.fixturePointer = outside
                            original.entered?()
                            checks["oldOwnerCannotOpenOutside"] = !self.hoverSourceContains(self.pointer,notch:true)
                            checks["focusPreserved"] = front == NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                            Capture.native(self.strip!.contentView!,to:out.appendingPathComponent("hover.png"))
                            try? JSONSerialization.data(withJSONObject:checks,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("checks.json"))
                            print(checks);fflush(stdout);NSApp.terminate(nil)
                        }
                    }
                }
            }
        }
    }
    private func runIslandMotion(at path:String,notice:Bool = false) {
        let out = URL(fileURLWithPath:path);try? FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        store.prefs.notchEnabled = true;store.prefs.notchStyle = "mixed"
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        updateStrip();let initial = strip!.frame;let windowID = strip!.windowNumber
        let compactPoint = NSPoint(x:initial.midX,y:initial.midY)
        let outsidePoint = NSPoint(x:initial.midX,y:initial.minY-150)
        let outsideReentry = CommandLine.arguments.contains("--outside-reentry")
        Capture.native(strip!.contentView!,to:out.appendingPathComponent("closed.png"))
        var contentChecks:[String:Bool] = [:]
        contentChecks["compactHoverAccepted"] = hoverSourceContains(compactPoint,notch:true)
        contentChecks["formerBodyHoverRejected"] = !hoverSourceContains(outsidePoint,notch:true)
        var frames:[[String:Double]] = [];var began = CACurrentMediaTime()
        let recorder = Timer(timeInterval:0.016,repeats:true) {[weak self] _ in MainActor.assumeIsolated {
            guard let island = self?.strip else{return}
            let shape = (island.contentView as? IslandContainer)?.presentedBounds ?? CGRect(origin:.zero,size:island.frame.size)
            frames.append(["t":CACurrentMediaTime()-began,"width":shape.width,"height":shape.height,"top":island.frame.maxY])
        }}
        RunLoop.main.add(recorder,forMode:.common)
        if notice {
            store.prefs.noticeSeconds = 0.9
            queueNotices([IslandNotice(stream:store.prefs.streams[0],windowID:"preview",kind:.reset,before:12,remaining:100,detail:"미리보기 · 5시간")])
        } else {
            // Warm SwiftUI layout before measuring the compositor, rather than
            // counting its first layout stall as animation time.
            showPanel(notch:true)
            if let content = strip?.contentView as? IslandContainer {
                content.reduceMotionOverride = CommandLine.arguments.contains("--reduced-motion") ? true : nil
                content.prepareCollapsed();CATransaction.flush();began = CACurrentMediaTime();content.transition(opening:true)
                let shadowPoint = strip!.convertPoint(toScreen:NSPoint(x:1,y:1))
                contentChecks["shadowDoesNotHoldOpen"] = !surfaceContains(shadowPoint,in:strip)
                if CommandLine.arguments.contains("--reverse-hover") || outsideReentry {
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.12) {[weak self] in self?.hidePanel()}
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.2) {
                        self.fixturePointer = outsideReentry ? outsidePoint : compactPoint
                        content.entered?()
                    }
                    if outsideReentry {
                        DispatchQueue.main.asyncAfter(deadline:.now()+0.35) {
                            contentChecks["outsideEnterCannotReverseClose"] = !self.islandExpanded
                        }
                        DispatchQueue.main.asyncAfter(deadline:.now()+0.8) {
                            content.entered?() // Obsolete tracking owner after close finished.
                        }
                    }
                }
                if CommandLine.arguments.contains("--left-before-open") {
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.12) {self.hidePanel()}
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.72) {
                        self.store.prefs.hoverDelay = 0.08;self.fixturePointer = compactPoint
                        self.queueOpen(notch:true)
                        self.fixturePointer = outsidePoint
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+(notice ? 0.85 : 1.0)) {[weak self] in
            guard let self,let island = self.strip else{return}
            Capture.native(island.contentView!,to:out.appendingPathComponent("expanded.png"))
            if outsideReentry {contentChecks["outsideEnterAfterCloseRejected"] = !self.islandExpanded && abs(island.frame.height-initial.height)<2}
            if CommandLine.arguments.contains("--left-before-open") {contentChecks["pointerRecheckedBeforeDelayedOpen"] = !self.islandExpanded}
            if let content = island.contentView as? IslandContainer {
                contentChecks["compactHeaderDissolved"] = notice ? content.header.layer?.opacity == 1 : content.header.layer?.opacity == 0
                contentChecks["bodyTopPlacement"] = content.detail.frame.minY == (notice ? content.headerSize.height : 0)
                if CommandLine.arguments.contains("--reverse-hover") {contentChecks["reenteredDuringClose"] = self.islandExpanded && content.detail.layer?.opacity == 1}
            }
            if !notice {self.hidePanel()}
            DispatchQueue.main.asyncAfter(deadline:.now()+0.7) {
                recorder.invalidate();let f = island.frame
                Capture.native(island.contentView!,to:out.appendingPathComponent("returned.png"))
                var checks:[String:Bool] = ["sameWindow":island.windowNumber == windowID,"returnedToCollapsed":abs(f.height-initial.height)<2 && abs(f.width-initial.width)<2,"cameraTopAnchored":frames.allSatisfy{abs(($0["top"] ?? 0)-initial.maxY)<1},"compositorIntermediateSizes":Set(frames.compactMap{$0["height"].map{Int($0)}}).count > 3,"focusPreserved":front == NSWorkspace.shared.frontmostApplication?.bundleIdentifier,"noticeAutoClosed": !notice || self.activeNotice == nil]
                checks.merge(contentChecks){_,new in new}
                let result:[String:Any] = ["checks":checks,"frames":frames]
                try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("motion.json"))
                print(checks);NSApp.terminate(nil)
            }
        }
    }
}

@MainActor enum Capture {
    static func policies(at path:String) {
        let out = URL(fileURLWithPath:path);try? FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        let sample = QuotaStore.fixture();let stream = sample.prefs.streams[1]
        sample.prefs.usagePolicies[stream.id] = UsagePolicy(mode:.deadline,deadlineAt:Date().addingTimeInterval(86400).timeIntervalSince1970,expectedResetAt:Date().addingTimeInterval(2*86400).timeIntervalSince1970,spendReserve:true)
        sample.dailyGoals.observe(prefs:sample.prefs,readings:sample.readings)
        render(UsagePolicyEditor(store:sample,stream:stream),width:520,to:out.appendingPathComponent("strategy-editor.png"))
        render(SettingsView(store:sample,initialTab:6),width:880,to:out.appendingPathComponent("strategy-settings.png"))
        render(QuotaPanel(store:sample,held:true,toggleHold:{},settings:{},close:{},demo:true,initialPage:2,embedded:true,cameraGap:196),width:604,to:out.appendingPathComponent("strategy-goals.png"))
        sample.panelPage = 3
        render(QuotaPanel(store:sample,held:true,toggleHold:{},settings:{},close:{},demo:true,initialPage:3,embedded:true,cameraGap:196),width:604,to:out.appendingPathComponent("strategy-plan.png"))
        if let account = sample.currentPlan.accounts.first(where:{$0.id == stream.id}) {render(GoalTargetEditor(store:sample,goals:sample.dailyGoals,account:account,openSettings:{}),width:280,to:out.appendingPathComponent("strategy-quick.png"))}
        sample.tokenHistory.period = .week
        render(TokenHistoryView(history:sample.tokenHistory,streams:sample.prefs.streams,initialDay:sample.tokenHistory.report().daily.last?.day),width:604,to:out.appendingPathComponent("chart-highlight.png"))
    }
    static func refinements(at path:String) {
        let out = URL(fileURLWithPath:path);try? FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        let sample = QuotaStore.fixture()
        render(QuotaPanel(store:sample,held:true,toggleHold:{},settings:{},close:{},demo:true),width:604,to:out.appendingPathComponent("overview.png"))
        render(QuotaPanel(store:sample,held:true,toggleHold:{},settings:{},close:{},demo:true,initialSelection:"codex"),width:604,to:out.appendingPathComponent("detail.png"))
        sample.prefs.showAllWindows = true
        render(QuotaPanel(store:sample,held:true,toggleHold:{},settings:{},close:{},demo:true),width:604,to:out.appendingPathComponent("all-windows.png"))
        sample.prefs.showAllWindows = false;sample.prefs.panelWidth = 560
        render(QuotaPanel(store:sample,held:true,toggleHold:{},settings:{},close:{},demo:true),width:560,to:out.appendingPathComponent("narrow.png"))
        sample.prefs.compact = true
        render(QuotaPanel(store:sample,held:true,toggleHold:{},settings:{},close:{},demo:true),width:560,to:out.appendingPathComponent("compact.png"))
        sample.panelPage = 2
        render(QuotaPanel(store:sample,held:true,toggleHold:{},settings:{},close:{},demo:true,initialPage:2),width:560,to:out.appendingPathComponent("goals.png"))
        sample.prefs.goalNearNotices = true
        render(SettingsView(store:sample,initialTab:2),width:880,to:out.appendingPathComponent("alerts.png"))
        for kind in [IslandNotice.Kind.pace,.goalNear,.goalReached] {
            let notice = IslandNotice(stream:sample.prefs.streams[0],windowID:"preview",kind:kind,before:35,remaining:kind == .goalReached ? 0 : 18,detail:"미리보기 · 오늘 목표 8.2 / 10%p")
            render(IslandNoticeView(notice:notice,settled:true),width:604,to:out.appendingPathComponent("notice-\(kind).png"))
        }
        sample.prefs.panelWidth = 604;sample.prefs.compact = false;sample.panelPage = 0
        let header = NSHostingView(rootView:NotchStrip(store:sample,notchWidth:196,height:32));header.sizingOptions = []
        let detail = NSHostingView(rootView:QuotaPanel(store:sample,held:true,toggleHold:{},settings:{},close:{},demo:true,embedded:true,cameraGap:196));detail.sizingOptions = []
        let surface = IslandContainer(header:header,detail:detail,width:604,headerSize:NSSize(width:362,height:32),headerOffset:0,detailSize:NSSize(width:604,height:sample.panelHeight))
        surface.layoutSubtreeIfNeeded()
        native(surface,to:out.appendingPathComponent("shadow-surface.png"),clipToIsland:false)
        let live = QuotaStore();live.panelPage = 1;live.tokenHistory.period = .all
        for month in ["2026-05","2026-06","2026-07","2026-08"] {
            live.tokenHistory.selectedMonth = month
            render(QuotaPanel(store:live,held:true,toggleHold:{},settings:{},close:{},initialPage:1),width:604,to:out.appendingPathComponent("history-\(month).png"))
        }
    }
    static func native(_ view:NSView,to file:URL,clipToIsland:Bool = true) {
        view.layoutSubtreeIfNeeded();view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds) else{return}
        view.cacheDisplay(in:view.bounds,to:rep)
        if clipToIsland,let island = view as? IslandContainer,let mask = island.exportPath {
            let image = NSImage(size:view.bounds.size)
            image.lockFocusFlipped(false)
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.translateBy(x:0,y:view.bounds.height);ctx.scaleBy(x:1,y:-1)
                ctx.addPath(mask);ctx.clip()
                ctx.scaleBy(x:1,y:-1);ctx.translateBy(x:0,y:-view.bounds.height)
                rep.draw(in:view.bounds)
            }
            image.unlockFocus()
            if let data = image.tiffRepresentation,let clipped = NSBitmapImageRep(data:data) {try? clipped.representation(using:.png,properties:[:])?.write(to:file)}
        } else {try? rep.representation(using:.png,properties:[:])?.write(to:file)}
    }
    static func render<V:View>(_ view:V,width:CGFloat,to file:URL) {
        let host = NSHostingView(rootView:view)
        host.appearance = NSAppearance(named:.darkAqua)
        let size = NSSize(width:width,height:host.fittingSize.height)
        host.frame = NSRect(origin:.zero,size:size)
        let window = NSWindow(contentRect:host.frame,styleMask:.borderless,backing:.buffered,defer:false)
        window.contentView = host;window.setFrameOrigin(NSPoint(x:-20000,y:-20000))
        host.layoutSubtreeIfNeeded();host.updateTrackingAreas();host.displayIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in:host.bounds) else{return}
        host.cacheDisplay(in:host.bounds,to:rep)
        try? rep.representation(using:.png,properties:[:])?.write(to:file)
        print("CAPTURE \(file.lastPathComponent) \(Int(size.width))×\(Int(size.height))")
    }
    static func renderReadmeScreenshots(into out:URL) {
        try? FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        let showcase = QuotaStore.showcase()
        render(QuotaPanel(store:showcase,held:false,toggleHold:{},settings:{},close:{},demo:true),width:604,to:out.appendingPathComponent("readme-usage.png"))
        render(SettingsView(store:showcase,initialTab:1),width:880,to:out.appendingPathComponent("readme-appearance.png"))
        showcase.panelPage = 1
        render(QuotaPanel(store:showcase,held:true,toggleHold:{},settings:{},close:{},demo:true,initialPage:1,embedded:true,cameraGap:196,heightOverride:584),width:604,to:out.appendingPathComponent("readme-history.png"))
        showcase.panelPage = 2
        render(QuotaPanel(store:showcase,held:true,toggleHold:{},settings:{},close:{},demo:true,initialPage:2,embedded:true,cameraGap:196),width:604,to:out.appendingPathComponent("readme-goals.png"))
        showcase.panelPage = 3
        render(QuotaPanel(store:showcase,held:true,toggleHold:{},settings:{},close:{},demo:true,initialPage:3,embedded:true,cameraGap:196),width:604,to:out.appendingPathComponent("readme-plan.png"))
        let showcaseWings = NotchLayout.wings(showcase.prefs,count:showcase.pinned.count)
        render(NotchStrip(store:showcase,notchWidth:184,height:32),width:184+showcaseWings.left+showcaseWings.right,to:out.appendingPathComponent("readme-notch.png"))
    }
    static func run(at path:String) {
        let out = URL(fileURLWithPath:path);try? FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        let defaults = QuotaStore.fixture()
        render(SettingsView(store:defaults,initialTab:1),width:880,to:out.appendingPathComponent("settings-defaults.png"))
        for kind in ["normal","stale","empty","long"] {
            let store = QuotaStore.fixture(kind)
            render(QuotaPanel(store:store,held:false,toggleHold:{},settings:{},close:{},demo:true),width:604,to:out.appendingPathComponent("panel-\(kind).png"))
        }
        let narrow = QuotaStore.fixture();narrow.prefs.panelWidth = 560;narrow.prefs.compact = true
        render(QuotaPanel(store:narrow,held:true,toggleHold:{},settings:{},close:{},demo:true),width:560,to:out.appendingPathComponent("panel-compact.png"))
        let store = QuotaStore.fixture()
        render(SettingsView(store:store,initialTab:0),width:880,to:out.appendingPathComponent("settings.png"))
        store.prefs.notchStyle = "compactNumbers"
        render(SettingsView(store:store,initialTab:1),width:880,to:out.appendingPathComponent("settings-appearance.png"))
        store.prefs.notchStyle = "mixed"
        render(SettingsView(store:store,initialTab:1),width:880,to:out.appendingPathComponent("settings-mixed.png"))
        render(SettingsView(store:store,initialTab:3),width:880,to:out.appendingPathComponent("settings-information.png"))
        render(SettingsView(store:store,initialTab:3,initialAccount:"grok"),width:880,to:out.appendingPathComponent("settings-information-grok.png"))
        render(SettingsView(store:store,initialTab:4),width:880,to:out.appendingPathComponent("settings-connections.png"))
        let grokStore = QuotaStore.fixture();grokStore.prefs.streams.removeAll{$0.source != "grok"}
        render(SettingsView(store:grokStore,initialTab:4),width:880,to:out.appendingPathComponent("settings-grok-connections.png"))
        store.prefs.showAllWindows = true
        render(QuotaPanel(store:store,held:true,toggleHold:{},settings:{},close:{},demo:true),width:604,to:out.appendingPathComponent("panel-all-windows.png"))
        let expiredStore = QuotaStore.fixture()
        expiredStore.prefs.showAllWindows = true
        for i in expiredStore.readings["claude"]!.snapshot!.windows.indices {expiredStore.readings["claude"]!.snapshot!.windows[i].resetsAt = Date().addingTimeInterval(-5)}
        expiredStore.readings["claude"]!.snapshot!.fetchedAt = Date().addingTimeInterval(-60)
        render(QuotaPanel(store:expiredStore,held:true,toggleHold:{},settings:{},close:{},demo:true),width:604,to:out.appendingPathComponent("panel-all-expired.png"))
        store.prefs.showAllWindows = false
        render(SettingsView(store:store,initialTab:2),width:880,to:out.appendingPathComponent("settings-alerts.png"))
        render(QuotaPanel(store:store,held:true,toggleHold:{},settings:{},close:{},demo:true,initialSelection:"claude"),width:604,to:out.appendingPathComponent("detail.png"))
        render(NotchStrip(store:store,notchWidth:184,height:32),width:316,to:out.appendingPathComponent("notch.png"))
        store.prefs.notchStyle = "numbers";store.prefs.wingWidth = 42
        render(NotchStrip(store:store,notchWidth:184,height:32),width:268,to:out.appendingPathComponent("notch-numbers-min.png"))
        var expired = store.readings["claude"]!.snapshot!
        for i in expired.windows.indices {expired.windows[i].resetsAt = Date().addingTimeInterval(-5)}
        expired.fetchedAt = Date().addingTimeInterval(-60)
        store.readings["claude"] = Reading(snapshot:expired)
        render(NotchStrip(store:store,notchWidth:184,height:32),width:268,to:out.appendingPathComponent("notch-numbers-expired.png"))
        let four = QuotaStore.fixture();four.prefs.notchStyle = "fourNumbers"
        let fourGap = NotchLayout.cameraGap(four.prefs,detected:0)
        let fourWings = NotchLayout.wings(four.prefs,count:four.pinned.count)
        render(NotchStrip(store:four,notchWidth:fourGap,height:32),width:fourGap+fourWings.left+fourWings.right,to:out.appendingPathComponent("notch-four-numbers.png"))
        for stream in four.prefs.streams {if four.readings[stream.id]?.snapshot != nil {for i in four.readings[stream.id]!.snapshot!.windows.indices {four.readings[stream.id]!.snapshot!.windows[i].usedPercent = 0}}}
        render(NotchStrip(store:four,notchWidth:fourGap,height:32),width:fourGap+fourWings.left+fourWings.right,to:out.appendingPathComponent("notch-four-hundreds.png"))
        render(SettingsView(store:four,initialTab:1),width:880,to:out.appendingPathComponent("settings-four-numbers.png"))
        let numbers = QuotaStore.fixture();numbers.prefs.notchStyle = "allNumbers"
        let gap = NotchLayout.cameraGap(numbers.prefs,detected:0)
        render(NotchStrip(store:numbers,notchWidth:gap,height:32),width:gap+NotchLayout.wing(numbers.prefs,count:numbers.pinned.count)*2,to:out.appendingPathComponent("notch-all-numbers-camera.png"))
        for kind:IslandNotice.Kind in [.reset,.low,.empty] {
            let s = store.prefs.streams.first!
            let notice = IslandNotice(stream:s,windowID:"demo",kind:kind,before:12,remaining:kind == .reset ? 100 : kind == .low ? 8 : 0,detail:"미리보기 · 5시간")
            render(IslandNoticeView(notice:notice,settled:true),width:440,to:out.appendingPathComponent("notice-\(kind).png"))
        }
        let tokenDemo = QuotaStore.fixture();tokenDemo.panelPage = 1
        render(SettingsView(store:tokenDemo,initialTab:5),width:880,to:out.appendingPathComponent("session-watches-empty.png"))
        render(SessionWatchSettings(directory:tokenDemo.directory,streams:tokenDemo.prefs.streams,previewRules:SessionWatchRule.samples).padding(30).frame(width:650,height:500,alignment:.top).background(Ink.ground).foregroundStyle(Ink.text).environment(\.colorScheme,.dark),width:650,to:out.appendingPathComponent("session-watches-active.png"))
        render(QuotaPanel(store:tokenDemo,held:true,toggleHold:{},settings:{},close:{},demo:true,initialPage:1,embedded:true,cameraGap:196),width:604,to:out.appendingPathComponent("tokens-models.png"))
        tokenDemo.tokenHistory.breakdown = "days"
        render(QuotaPanel(store:tokenDemo,held:true,toggleHold:{},settings:{},close:{},demo:true,initialPage:1),width:604,to:out.appendingPathComponent("tokens-days.png"))
        tokenDemo.tokenHistory.breakdown = "projects"
        let sampleProjects = tokenDemo.tokenHistory.cache.projects
        tokenDemo.tokenHistory.cache.projects = ProjectArchive()
        render(QuotaPanel(store:tokenDemo,held:true,toggleHold:{},settings:{},close:{},demo:true,initialPage:1),width:604,to:out.appendingPathComponent("tokens-projects-empty.png"))
        tokenDemo.tokenHistory.cache.projects = sampleProjects
        tokenDemo.tokenHistory.period = .today;tokenDemo.tokenHistory.breakdown = "models"
        render(QuotaPanel(store:tokenDemo,held:true,toggleHold:{},settings:{},close:{},demo:true,initialPage:1),width:604,to:out.appendingPathComponent("tokens-today-hours.png"))
        let planDemo = QuotaStore.fixture();planDemo.panelPage = 2
        planDemo.dailyGoals.observe(prefs:planDemo.prefs,readings:planDemo.readings)
        render(SettingsView(store:planDemo,initialTab:6),width:880,to:out.appendingPathComponent("goals-settings-auto.png"))
        planDemo.prefs.planPriority = ["claude","codex"]
        planDemo.prefs.dailyGoalTargets["claude"] = 12
        planDemo.dailyGoals.target("claude",value:12)
        render(SettingsView(store:planDemo,initialTab:6),width:880,to:out.appendingPathComponent("goals-settings-custom.png"))
        render(QuotaPanel(store:planDemo,held:true,toggleHold:{},settings:{},close:{},demo:true,initialPage:2,embedded:true,cameraGap:196),width:604,to:out.appendingPathComponent("goals-normal.png"))
        planDemo.panelPage = 3
        render(QuotaPanel(store:planDemo,held:true,toggleHold:{},settings:{},close:{},demo:true,initialPage:3,embedded:true,cameraGap:196),width:604,to:out.appendingPathComponent("plan-normal.png"))
        render(PlanOptionsPopover(store:planDemo,openSettings:{}).environment(\.colorScheme,.dark),width:330,to:out.appendingPathComponent("plan-options.png"))
        renderReadmeScreenshots(into:out)
        // Work basis with example estimates; restored before the later captures.
        let exampleSizes:[String:Double] = ["claude":1_200_000,"codex":2_000_000]
        for (id,size) in exampleSizes {planDemo.capacity.estimates[id] = CapacityEstimate(tokensPerPoint:size,points:120,windows:3,method:"example",measuredAt:.now)}
        for id in ["agy-claude","agy-general","kiro","grok"] {planDemo.capacity.estimates[id] = CapacityEstimate(method:"none",note:"Teum이 읽는 토큰 기록 없음",measuredAt:.now)}
        planDemo.capacity.estimatedAt = .now;planDemo.prefs.planBasis = "work"
        render(QuotaPanel(store:planDemo,held:true,toggleHold:{},settings:{},close:{},demo:true,initialPage:3,embedded:true,cameraGap:196),width:604,to:out.appendingPathComponent("plan-work.png"))
        planDemo.panelPage = 2
        render(QuotaPanel(store:planDemo,held:true,toggleHold:{},settings:{},close:{},demo:true,initialPage:2,embedded:true,cameraGap:196),width:604,to:out.appendingPathComponent("goals-work.png"))
        render(PlanOptionsPopover(store:planDemo,openSettings:{},expandCapacity:true).environment(\.colorScheme,.dark),width:330,to:out.appendingPathComponent("plan-options-work.png"))
        planDemo.capacity = CapacityBook();planDemo.prefs.planBasis = "percent";planDemo.panelPage = 3
        if let targetAccount = planDemo.currentPlan.accounts.first {
            render(GoalTargetEditor(store:planDemo,goals:planDemo.dailyGoals,account:targetAccount,openSettings:{}).environment(\.colorScheme,.dark),width:280,to:out.appendingPathComponent("goal-editor.png"))
        }

        render(QuotaPlanView(store:planDemo).frame(width:604,height:580).background(.black).foregroundStyle(Ink.text).environment(\.colorScheme,.dark),width:604,to:out.appendingPathComponent("plan-weekly.png"))
        let todayKey = DailyGoalsStore.key(.now)
        planDemo.dailyGoals.ledger.days[todayKey]?.used["claude"] = 15
        render(QuotaPanel(store:planDemo,held:true,toggleHold:{},settings:{},close:{},demo:true,initialPage:2,embedded:true,cameraGap:196),width:604,to:out.appendingPathComponent("goals-exceeded.png"))
        planDemo.prefs.planExcluded = planDemo.prefs.streams.map(\.id)
        render(QuotaPanel(store:planDemo,held:true,toggleHold:{},settings:{},close:{},demo:true,initialPage:2),width:604,to:out.appendingPathComponent("goals-empty.png"))
        planDemo.panelPage = 3
        render(QuotaPanel(store:planDemo,held:true,toggleHold:{},settings:{},close:{},demo:true,initialPage:3),width:604,to:out.appendingPathComponent("plan-empty.png"))
        let planNarrow = QuotaStore.fixture();planNarrow.prefs.panelWidth = 560;planNarrow.prefs.showFooter = false;planNarrow.panelPage = 2
        render(QuotaPanel(store:planNarrow,held:true,toggleHold:{},settings:{},close:{},demo:true,initialPage:2,embedded:true,cameraGap:300),width:560,to:out.appendingPathComponent("goals-narrow.png"))
        planNarrow.panelPage = 3
        render(QuotaPanel(store:planNarrow,held:true,toggleHold:{},settings:{},close:{},demo:true,initialPage:3,embedded:true,cameraGap:300),width:560,to:out.appendingPathComponent("plan-narrow.png"))
        planNarrow.prefs.panelWidth = 604;planNarrow.prefs.showFooter = true;planNarrow.prefs.planScope = "all"
        render(QuotaPanel(store:planNarrow,held:true,toggleHold:{},settings:{},close:{},demo:true,initialPage:3,embedded:true,cameraGap:196),width:604,to:out.appendingPathComponent("plan-all.png"))
        let live = QuotaStore(ephemeral:false)
        render(QuotaPanel(store:live,held:false,toggleHold:{},settings:{},close:{}),width:604,to:out.appendingPathComponent("panel-live.png"))
        let liveWidth = live.prefs.panelWidth;live.prefs.panelWidth = 560
        render(QuotaPanel(store:live,held:false,toggleHold:{},settings:{},close:{}),width:560,to:out.appendingPathComponent("panel-live-narrow.png"))
        live.prefs.panelWidth = liveWidth
        let liveWings = NotchLayout.wings(live.prefs,count:live.pinned.count)
        render(NotchStrip(store:live,notchWidth:196,height:32),width:196+liveWings.left+liveWings.right,to:out.appendingPathComponent("notch-live.png"))
        // Real readings: run-out forecast and Codex reset credits in the detail.
        render(QuotaPanel(store:live,held:true,toggleHold:{},settings:{},close:{},initialSelection:"codex"),width:604,to:out.appendingPathComponent("detail-codex-live.png"))
        live.panelPage = 1
        render(QuotaPanel(store:live,held:true,toggleHold:{},settings:{},close:{},initialPage:1,embedded:true,cameraGap:196),width:604,to:out.appendingPathComponent("tokens-live.png"))
        live.tokenHistory.period = .quarter
        render(QuotaPanel(store:live,held:true,toggleHold:{},settings:{},close:{},initialPage:1,embedded:true,cameraGap:196),width:604,to:out.appendingPathComponent("tokens-90-live.png"))
        live.tokenHistory.period = .all
        render(QuotaPanel(store:live,held:true,toggleHold:{},settings:{},close:{},initialPage:1,embedded:true,cameraGap:196),width:604,to:out.appendingPathComponent("tokens-all-live.png"))
        live.tokenHistory.period = .week
        live.tokenHistory.breakdown = "projects"
        render(QuotaPanel(store:live,held:true,toggleHold:{},settings:{},close:{},initialPage:1,embedded:true,cameraGap:196),width:604,to:out.appendingPathComponent("tokens-projects-live.png"))
        live.panelPage = 2
        render(QuotaPanel(store:live,held:true,toggleHold:{},settings:{},close:{},initialPage:2,embedded:true,cameraGap:196),width:604,to:out.appendingPathComponent("goals-live.png"))
        live.panelPage = 3
        render(QuotaPanel(store:live,held:true,toggleHold:{},settings:{},close:{},initialPage:3,embedded:true,cameraGap:196),width:604,to:out.appendingPathComponent("plan-live.png"))
        live.panelPage = 1
        live.tokenHistory.period = .today;live.tokenHistory.breakdown = "models"
        render(QuotaPanel(store:live,held:true,toggleHold:{},settings:{},close:{},initialPage:1,embedded:true,cameraGap:196),width:604,to:out.appendingPathComponent("tokens-today-live.png"))
        tokenDemo.prefs.panelWidth = 560;tokenDemo.prefs.showFooter = false
        tokenDemo.tokenHistory.breakdown = "models";tokenDemo.tokenHistory.period = .quarter
        render(QuotaPanel(store:tokenDemo,held:true,toggleHold:{},settings:{},close:{},demo:true,initialPage:1,embedded:true,cameraGap:300),width:560,to:out.appendingPathComponent("tokens-narrow-no-status.png"))
        tokenDemo.tokenHistory.cache = TokenHistoryCache();tokenDemo.prefs.showFooter = true
        render(QuotaPanel(store:tokenDemo,held:true,toggleHold:{},settings:{},close:{},demo:true,initialPage:1),width:560,to:out.appendingPathComponent("tokens-empty.png"))
        tokenDemo.tokenHistory.reading = true
        render(QuotaPanel(store:tokenDemo,held:true,toggleHold:{},settings:{},close:{},demo:true,initialPage:1),width:560,to:out.appendingPathComponent("tokens-loading.png"))
    }
}

@MainActor enum Probe {
    static func write(_ store:QuotaStore) {
        for s in store.prefs.streams {
            let r = store.readings[s.id] ?? Reading()
            print("\(s.name) · \(r.error ?? "정상") · \(r.snapshot?.planName ?? "")")
            for w in r.windows {print("  \(WindowLogic.label(w)) \(WindowLogic.remaining(w).map{String(format:"%.1f%% 남음",$0)} ?? "값 없음") · \(WindowLogic.exact(w.resetsAt))")}
        }
    }
}

@MainActor enum SelfTest {
    static func run() -> Bool {
        var failures:[String] = [];var count = 0
        func check(_ condition:Bool,_ name:String){count += 1;if !condition {failures.append(name)}}
        let fillView = QuotaFillView(frame:NSRect(x:0,y:0,width:200,height:3))
        fillView.configure(value:50,color:.systemBlue,delay:0.08,animated:true);fillView.layout()
        let fillLayer = fillView.layer!.sublayers!.first!
        let reveal = fillLayer.animation(forKey:"quota-fill")
        check(fillView.bounds.width == 200 && fillLayer.bounds.width == 100 && reveal?.duration == 0.65,"막대 채우기는 뷰 크기 고정·레이어만 재생")
        fillView.configure(value:50,color:.systemBlue,delay:0.08,animated:true);fillView.layout()
        check(fillLayer.animation(forKey:"quota-fill")?.beginTime == reveal?.beginTime,"같은 값 재렌더는 막대 재생을 다시 시작하지 않음")
        fillView.configure(value:75,color:.systemBlue,delay:0.08,animated:true);fillView.layout()
        check(fillLayer.bounds.width == 150 && fillLayer.animation(forKey:"quota-fill")?.duration == 0.35,"실제 잔여 변경도 레이어로 갱신")
        fillView.configure(value:90,color:.systemBlue,delay:0,animated:false);fillView.layout()
        check(fillLayer.bounds.width == 180 && fillLayer.animation(forKey:"quota-fill") == nil,"정지·동작 줄이기는 즉시 실제 값")
        fillView.frame.size.width = 300;fillView.layout()
        check(fillLayer.bounds.width == 270,"막대 컨테이너 크기를 바꾸면 비율 유지")
        for (name,condition) in UsagePolicyChecks.run() {check(condition,name)}
        for (name,condition) in DistributionChecks.run() {check(condition,name)}
        let store = QuotaStore.fixture()
        check(store.visible.count == 6,"그록 포함 6개 계정 표시")
        check(store.warningStreams.isEmpty,"제외한 키로는 경고 없음")
        store.prefs.streams[4].warns = true
        check(store.warningStreams.map(\.id) == ["kiro"],"잔여 0 키로만 경고")
        store.prefs.threshold = 20
        check(Set(store.warningStreams.map(\.id)) == Set(["claude","kiro"]),"주간 클로드 경고")
        let weekly = store.readings["claude"]!.windows[1]
        store.prefs.streams[0].ignoredWindows = [weekly.id]
        check(store.warningStreams.map(\.id) == ["kiro"],"한도별 경고 제외")
        store.readings["kiro"]?.error = "오프라인"
        check(store.warningStreams.isEmpty,"오래된 값은 경고 없음")
        check(store.readings["kiro"]?.windows.first?.usedPercent == 100,"오류 시 이전 수치 유지")
        let claude = store.readings["claude"]!.windows
        check(WindowLogic.selected(claude,choice:"short")?.usedPercent == 4,"노치 단기 한도 선택")
        check(WindowLogic.selected(claude,choice:"week")?.usedPercent == 84,"노치 주간 한도 선택")
        check(WindowLogic.selected(claude,choice:"id:"+claude[0].id)?.id == claude[0].id,"모델별 실제 한도 선택")
        check(WindowLogic.selected(claude,choice:"month") == nil,"미지원 월간을 주간으로 대체 금지")
        check(WindowLogic.selected(claude,choice:"none") == nil,"호버 한도 숨기기")
        var legacyPrefs = Preferences();legacyPrefs.streams.removeAll{$0.id == "grok"}
        legacyPrefs.streams[0].name = "이름 유지"
        let migrated = Preferences.read(try! JSONEncoder().encode(legacyPrefs))!
        check(migrated.streams.count == 6 && migrated.streams[0].name == "이름 유지","기존 이름과 순서 보존하며 그록 추가")
        let heightBefore = store.panelHeight;store.prefs.showFooter = false
        check(store.panelHeight == heightBefore-16,"상태 문구를 숨겨도 하단 페이지 점 영역은 유지")
        store.prefs.showFooter = true
        check(ConnectionAction.loginCommand(Stream(id:"codex-work",name:"코덱스 work",source:"codex",profile:"work"))?.contains(".codex-work") == true,"워킹 프로필 CLI 재연결 격리")
        check(ConnectionAction.loginCommand(Stream(id:"codex-team",name:"코덱스 team",source:"codex",profile:"team"))?.contains(".codex-team") == true,"팀 프로필 CLI 재연결 격리")
        check(ConnectionAction.loginCommand(Stream.defaults[5]) == nil,"그록 웹훅 CLI를 로그인 명령으로 실행 금지")
        let grokQuota:[String:Any] = ["value":["value":["status":200,"availability":"available","weeklyIncludedUsage":["usedCents":365.0,"budgetCents":4615.0,"periodStart":"2026-10-30T06:21:31.377Z","resetsAt":"2026-11-06T06:21:31.377Z"]]]]
        let grokValue = try? GrokDashboard.parse(grokQuota)
        check(grokValue?.windows.first?.windowSeconds == 604800 && abs((grokValue?.windows.first?.usedPercent ?? 0)-7.909)<0.01,"그록 공식 주간 응답 해석")
        check((try? GrokDashboard.parse(["status":401])) == nil,"그록 로그인 오류를 0퍼센트로 변환 금지")
        check((try? GrokDashboard.parse(["status":200,"availability":"available","weeklyIncludedUsage":["usedCents":0,"budgetCents":0]])) == nil,"그록 미제공 한도를 100퍼센트로 변환 금지")
        let disconnected = QuotaStore.fixture()
        disconnected.setConnected("agy-claude",false)
        check(disconnected.prefs.streams.filter{$0.source == "agy"}.allSatisfy{$0.connected == false},"AGY 두 한도 연결 해제 동기화")
        check(disconnected.readings["agy-claude"]?.snapshot == nil && !disconnected.pinned.contains(where:{$0.source == "agy"}),"해제된 연결의 캐시와 노치 표시 제거")
        disconnected.setConnected("agy-general",true)
        check(disconnected.prefs.streams.filter{$0.source == "agy"}.allSatisfy{$0.connected == true},"AGY 연결 재개 동기화")
        check(WindowLogic.resetDisplay(nil,style:"absolute") == "리셋 시각 없음","일시 미제공을 임의 날짜로 대체 금지")
        check(WindowLogic.resetDisplay(Date(timeIntervalSince1970:1793946091),style:"absolute").contains("11월 6일"),"리셋 월일과 시각 표시")
        check(WindowLogic.selected(claude,choice:"auto")?.id == claude[1].id,"자동은 단기·주간 중 최소 잔여 선택")
        var autoChange = claude;autoChange[0].usedPercent = 99
        check(WindowLogic.selected(autoChange,choice:"auto")?.id == claude[0].id,"새 사용량에 따라 자동 한도 변경")
        let profileHome = FileManager.default.temporaryDirectory.appendingPathComponent("Teum-profiles-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:profileHome)}
        try! FileManager.default.createDirectory(at:profileHome.appendingPathComponent(".codex"),withIntermediateDirectories:true)
        try! Data("{}".utf8).write(to:profileHome.appendingPathComponent(".codex/auth.json"))
        check(CodexProfiles.initial(home:profileHome).streams.filter{$0.source == "codex"}.count == 1,"단일 코덱스 로그인은 한 행만 생성")
        try! FileManager.default.createDirectory(at:profileHome.appendingPathComponent(".codex-work"),withIntermediateDirectories:true)
        try! Data("{}".utf8).write(to:profileHome.appendingPathComponent(".codex-work/auth.json"))
        try! FileManager.default.createSymbolicLink(at:profileHome.appendingPathComponent(".codex-alias"),withDestinationURL:profileHome.appendingPathComponent(".codex"))
        let foundProfiles = CodexProfiles.discover(home:profileHome)
        check(foundProfiles.count == 2 && foundProfiles.contains(where:{$0.id == "codex-work"}),"여러 프로필 감지와 심볼릭 링크 중복 제거")
        check(CodexProfiles.initial(home:profileHome).streams.filter{$0.source == "codex"}.count == 2,"새 사용자의 감지된 프로필만 초기 표시")
        var testCalendar = Calendar(identifier:.gregorian);testCalendar.timeZone = TimeZone(identifier:"Asia/Seoul")!;testCalendar.firstWeekday = 2
        let dateParts:([Int])->Date = {v in testCalendar.date(from:DateComponents(year:v[0],month:v[1],day:v[2],hour:v[3],minute:v[4]))!}
        let calendarNow = dateParts([2026,10,31,20,0])
        check(WindowLogic.resetDisplay(dateParts([2026,10,31,22,49]),style:"calendar",now:calendarNow,calendar:testCalendar) == "오늘 22:49","오늘 리셋 시각 표현")
        check(WindowLogic.resetDisplay(dateParts([2026,11,1,9,0]),style:"calendar",now:calendarNow,calendar:testCalendar) == "내일 09:00","월 경계의 내일 리셋 표현")
        check(WindowLogic.resetDisplay(dateParts([2026,11,6,15,21]),style:"calendar",now:calendarNow,calendar:testCalendar) == "다음 주 금요일 15:21","다음 주 요일과 시각 표현")
        check(WindowLogic.resetDisplay(dateParts([2026,10,31,22,49]),style:"calendar",todayTomorrow:false,weekdays:false,now:calendarNow,calendar:testCalendar) == "10월 31일 22:49","간편 날짜 두 옵션 해제 시 정확한 일시")
        check(WindowLogic.resetDisplay(dateParts([2026,11,2,0,0]),style:"calendar",now:calendarNow,calendar:testCalendar) == "다음 주 월요일 00:00","주 시작 경계 일시 구분")
        let hitParent = NSView(frame:NSRect(x:0,y:0,width:668,height:440))
        let hitDetail = NSView()
        let hitIsland = IslandContainer(header:NSView(),detail:hitDetail,width:604,headerSize:NSSize(width:362,height:32),headerOffset:0,detailSize:NSSize(width:604,height:400))
        hitParent.addSubview(hitIsland);hitIsland.layoutSubtreeIfNeeded()
        var alignedHits = true
        for (x,y) in [(40.0,80.0),(160.0,80.0),(320.0,180.0),(500.0,280.0)] {
            let marker = NSView(frame:NSRect(x:x,y:y,width:24,height:24));hitDetail.addSubview(marker)
            let point = marker.convert(NSPoint(x:12,y:12),to:hitParent)
            alignedHits = alignedHits && hitParent.hitTest(point) === marker
        }
        check(alignedHits,"확장 섬 네 지점의 표시 위치와 실제 클릭 좌표 일치")
        var planPrefs = Preferences();planPrefs.streams = [Stream.defaults[0],Stream.defaults[1],Stream.defaults[3],Stream.defaults[5],Stream.defaults[4]]
        let planNow = Date();let day:Double = 86400
        func planningReading(_ left:Double,days:Double,short:Double? = nil)->Reading {
            var windows = [UsageWindow(title:"Weekly window",usedPercent:100-left,resetsAt:planNow.addingTimeInterval(days*day),windowSeconds:604800)]
            if let short {windows.append(UsageWindow(title:"5-hour window",usedPercent:100-short,resetsAt:planNow.addingTimeInterval(6*3600),windowSeconds:18000))}
            return Reading(snapshot:UsageSnapshot(windows:windows,fetchedAt:planNow))
        }
        var planReadings:[String:Reading] = ["claude":planningReading(80,days:2),"codex":planningReading(50,days:1),"agy-general":planningReading(90,days:3,short:0),"grok":planningReading(60,days:2),"kiro":Reading(snapshot:UsageSnapshot(windows:[UsageWindow(title:"Monthly credits",usedPercent:10)],fetchedAt:planNow))]
        let plan = QuotaPlanner.build(prefs:planPrefs,readings:planReadings,now:planNow)
        check(plan.next?.id == "codex","배분 계획은 잔여 가용량÷리셋 남은 시간으로 순위 계산")
        check(plan.accounts.last?.id == "agy-general" && plan.accounts.last?.shortBlocked == true,"단기 소진 계정은 즉시 사용 추천에서 대기")
        let beforeReset = PlanDay(start:planNow,end:planNow.addingTimeInterval(2*day))
        check(abs((plan.allocations(day:beforeReset).first{$0.id == "claude"}?.points ?? 0)-70)<0.00001,"현재 주기 할당 합계는 실제 잔여에서 보호10%를 뺀 값")
        let early = PlanDay(start:planNow,end:planNow.addingTimeInterval(3*3600))
        check(!plan.allocations(day:early).contains{$0.id == "agy-general"},"단기 재개 이전 시간에는 사용 목표를 만들지 않음")
        let afterReset = PlanDay(start:planNow.addingTimeInterval(2*day),end:planNow.addingTimeInterval(3*day))
        let projected = plan.allocations(day:afterReset).first{$0.id == "claude"}
        check(projected?.projected == true && abs((projected?.points ?? 0)-90/7)<0.00001,"리셋 뒤 구간은 예상으로 구분하고 새 주기90%를 시간 비율로 배분")
        check(plan.omitted.contains{$0.id == "grok"} && plan.omitted.contains{$0.id == "kiro"},"코딩 범위와 주간 없는 계정을 임의 환산하지 않음")
        planPrefs.planScope = "all"
        check(QuotaPlanner.build(prefs:planPrefs,readings:planReadings,now:planNow).accounts.contains{$0.id == "grok"},"전체 계정 선택 시 실제 Grok 주간 포함")
        planPrefs.planScope = "coding";planPrefs.planExcluded = ["codex"]
        check(QuotaPlanner.build(prefs:planPrefs,readings:planReadings,now:planNow).next?.id == "claude","사용자가 계획에서 제외한 계정은 순위에서 빠짐")
        planPrefs.planExcluded = [];planPrefs.streams[0].warns = false;planPrefs.streams[0].ignoredWindows = ["Weekly window"]
        check(QuotaPlanner.build(prefs:planPrefs,readings:planReadings,now:planNow).accounts.contains{$0.id == "claude"},"경고 제외가 배분 계획 대상 제외로 오해되지 않음")
        planReadings["codex"]?.error = "offline"
        check(!QuotaPlanner.build(prefs:planPrefs,readings:planReadings,now:planNow).accounts.contains{$0.id == "codex"},"오프라인 이전 값은 새 배분 추천에서 제외")
        check(plan.days.first?.start == planNow && plan.days.last?.end == plan.end && zip(plan.days,plan.days.dropFirst()).allSatisfy{$0.end == $1.start},"7일 구간은 자정에 나누되 틈과 중복 없이 이어짐")
        check(plan.days.flatMap{plan.allocations(day:$0)}.allSatisfy{$0.points.isFinite && $0.points>=0} && JSONSerialization.isValidJSONObject(QuotaPlanner.json(plan)),"계획 수치가 유한·비음수이며 AI용 JSON 직렬화 가능")
        planPrefs.planPriority = ["claude"]
        check(QuotaPlanner.build(prefs:planPrefs,readings:planReadings,now:planNow).next?.id == "claude","선호 AI는 사용 가능한 한도 내에서 우선 추천")
        planReadings["codex"]?.error = nil
        check(QuotaPlanner.build(prefs:planPrefs,readings:planReadings,now:planNow,dailyRemaining:["claude":0]).next?.id == "codex","선호 AI여도 오늘 목표를 다 쓰면 다른 계정 추천")
        let goalLinked = QuotaPlanner.build(prefs:planPrefs,readings:planReadings,now:planNow,dailyRemaining:["claude":3])
        let goalAccount = goalLinked.accounts.first{$0.id == "claude"}!
        check(abs((goalLinked.allocations(day:goalLinked.days[0]).first{$0.id == "claude"}?.points ?? 0)-3)<0.0001,"배분표 오늘 몫은 목표 페이지의 남은3%p와 연동")
        let currentCycle = PlanDay(start:planNow,end:goalAccount.reset)
        check(abs((goalLinked.allocations(day:currentCycle).first{$0.id == "claude"}?.points ?? 0)-goalAccount.spendable)<0.0001,"오늘 목표 반영 후 나머지 날짜 재배분도 주간 사용가능량 보존")
        var resetToday = goalLinked
        resetToday.accounts = [goalAccount];resetToday.accounts[0].reset = planNow.addingTimeInterval(3600)
        let linkedToday = resetToday.allocations(day:resetToday.days[0]).first
        check(abs((linkedToday?.points ?? 0)-3)<0.0001 && linkedToday?.projected == false,"오늘 주간 리셋이 있어도 일일 목표 중복 배정·가짜 예상표시 방지")
        var ledger = GoalLedger();let goalDay = DailyGoalsStore.key(planNow)
        let goalStart = Calendar.current.startOfDay(for:planNow).addingTimeInterval(3600)
        ledger.observe(id:"test",window:"week",remaining:50,at:goalStart,day:goalDay)
        ledger.observe(id:"test",window:"week",remaining:40,at:goalStart.addingTimeInterval(60),day:goalDay)
        ledger.observe(id:"test",window:"week",remaining:100,at:goalStart.addingTimeInterval(120),day:goalDay)
        ledger.observe(id:"test",window:"week",remaining:95,at:goalStart.addingTimeInterval(180),day:goalDay)
        check(ledger.days[goalDay]?.used["test"] == 15,"오늘 관측 사용은 리셋 전후 감소분을 이어 합산하고 회복분 차감 금지")
        ledger.observe(id:"test",window:"week",remaining:90,at:goalStart.addingTimeInterval(100),day:goalDay)
        check(ledger.days[goalDay]?.used["test"] == 15,"늦게 도착한 과거 조회가 일일 사용을 중복 집계하지 않음")
        let paceWindow = UsageWindow(title:"weekly",usedPercent:80,resetsAt:planNow.addingTimeInterval(302400),windowSeconds:604800)
        check(PaceGuide.remaining(paceWindow,now:planNow) == 50,"고른 사용 기준은 잔여 시간이 주기 절반이면50%")
        var expiredPace = paceWindow;expiredPace.resetsAt = planNow.addingTimeInterval(-1)
        check(PaceGuide.remaining(expiredPace,now:planNow) == nil,"지난 리셋 시각에는 고른 사용 기준선을 그리지 않음")
        let nextDay = goalStart.addingTimeInterval(86400),nextKey = DailyGoalsStore.key(nextDay)
        ledger.observe(id:"test",window:"week",remaining:90,at:nextDay,day:nextKey)
        check((ledger.days[nextKey]?.used["test"] ?? 0) == 0 && ledger.days[goalDay]?.used["test"] == 15,"자정이 지나면 이전 날 감소분을 새 목표에 섞지 않음")
        check(PanelPages.clamped(-1) == 0 && PanelPages.clamped(2) == 2 && PanelPages.clamped(3) == 3 && PanelPages.clamped(4) == 3,"오늘 목표와 배분 계획은 독립된 네 페이지의2·3번")
        var swipe = PageSwipeGate();var moves = 0
        _ = swipe.feed(x:0,y:0,phase:.began,momentum:false,time:1)
        for i in 0..<30 {if swipe.feed(x:-10,y:1,phase:.changed,momentum:false,time:1+Double(i)*0.01).step != nil {moves += 1}}
        _ = swipe.feed(x:0,y:0,phase:.ended,momentum:false,time:1.31)
        for i in 0..<60 {if swipe.feed(x:-20,y:0,phase:.unphased,momentum:true,time:1.32+Double(i)*0.02).step != nil {moves += 1}}
        check(moves == 1,"한 스와이프와 관성60개 패킷은 한 번만 전환")
        _ = swipe.feed(x:0,y:0,phase:.began,momentum:false,time:3)
        check(swipe.feed(x:60,y:0,phase:.changed,momentum:false,time:3.1).step == -1,"다음 물리 스와이프에서 역방향 한 번 허용")
        var vertical = PageSwipeGate();_ = vertical.feed(x:0,y:0,phase:.began,momentum:false,time:1)
        _ = vertical.feed(x:3,y:60,phase:.changed,momentum:false,time:1.1)
        check(vertical.feed(x:-100,y:2,phase:.changed,momentum:false,time:1.2).step == nil,"세로 스크롤 중 가로 오차로 페이지 전환 금지")
        var wheel = PageSwipeGate();var wheelMoves = 0
        for i in 0..<30 {if wheel.feed(x:-10,y:0,phase:.unphased,momentum:false,time:Double(i)*0.01).step != nil {wheelMoves += 1}}
        check(wheelMoves == 1,"단계 없는 휠 이벤트 묶음도 한 번만 전환")
        var preciseSwipe = PageSwipeGate()
        _ = preciseSwipe.feed(x:0,y:0,phase:.began,momentum:false,time:0)
        check(preciseSwipe.feed(x:-16,y:1,phase:.changed,momentum:false,time:0.01,precise:true).step == 1,"정밀 스와이프는 16pt에서 바로 전환")
        check(preciseSwipe.feed(x:-80,y:0,phase:.changed,momentum:false,time:0.02,precise:true).step == nil,"가벼운 입력 기준에서도 한 제스처 한 페이지 유지")
        var coarseSwipe = PageSwipeGate()
        check(coarseSwipe.feed(x:-16,y:0,phase:.unphased,momentum:false,time:0,precise:false).step == nil,"일반 휠은 기존 42pt 기준 유지")
        check(coarseSwipe.feed(x:-26,y:0,phase:.unphased,momentum:false,time:0.1,precise:false).step == 1,"일반 휠 누적 판정 유지")
        check(PanelPages.next(3,by:1) == 0 && PanelPages.next(0,by:-1) == 3,"양 끝 페이지에서 반대 끝으로 순환")
        check(PanelPages.next(0,by:2) == 2 && PanelPages.next(3,by:-2) == 1,"페이지 점과 접근성 이동은 정상 위치")
        let nav = PanelNavigation();nav.go(to:3,step:-1)
        check(nav.page == 3 && nav.direction == -1 && nav.animated,"뒤로 순환하면 왼쪽에서 들어오는 슬라이드")
        nav.go(to:0,animated:false)
        check(nav.page == 0 && !nav.animated,"코드에서 바꾼 페이지는 슬라이드 없이 이동")
        let pageStore = QuotaStore.fixture();var storeChanges = 0
        let storeWatch = pageStore.objectWillChange.sink{_ in storeChanges += 1}
        pageStore.panelPage = 2
        check(storeChanges == 0 && pageStore.navigation.page == 2,"페이지 변경이 저장소를 보는 모든 화면을 다시 그리지 않음")
        storeWatch.cancel()
        let pageStrip = PageStripView(count:4,initial:0){_ in NSView()}
        pageStrip.frame = NSRect(x:0,y:0,width:100,height:50);pageStrip.layout()
        var settledPage = -1;pageStrip.settled = {settledPage = $0}
        pageStrip.show(2,direction:1,animated:true)
        check(pageStrip.current == 2 && settledPage == 2 && pageStrip.pageView(2)?.isHidden == false && pageStrip.pageView(0)?.isHidden == true,"창 밖에서는 슬라이드 없이 바로 이동")
        check(pageStrip.mountedPages == [0,2],"보지 않은 페이지는 필요할 때 만듦")
        let paceNow = Date(timeIntervalSince1970:1_793_500_000)
        let burning = UsageWindow(title:"Weekly window",usedPercent:84,resetsAt:paceNow.addingTimeInterval(2.3*86400),windowSeconds:604800)
        check(RunOut.date(burning,now:paceNow).map{abs($0.timeIntervalSince(paceNow)/86400-0.8952)<0.005} == true,"주기 평균 속도로 소진 예상 시각 계산")
        check(RunOut.detail(burning,now:paceNow)?.warning == true,"리셋 전에 바닥나면 상세에 경고")
        let steady = UsageWindow(title:"Weekly window",usedPercent:30,resetsAt:paceNow.addingTimeInterval(2.3*86400),windowSeconds:604800)
        check(RunOut.date(steady,now:paceNow) == nil && RunOut.detail(steady,now:paceNow)?.warning == false,"리셋까지 버티면 소진 예상을 띄우지 않음")
        let youngWindow = UsageWindow(title:"5-hour window",usedPercent:3,resetsAt:paceNow.addingTimeInterval(18000-120),windowSeconds:18000)
        check(RunOut.date(youngWindow,now:paceNow) == nil && RunOut.detail(youngWindow,now:paceNow) == nil,"주기 초반 2분의 속도로는 예측하지 않음")
        check(RunOut.date(UsageWindow(title:"Monthly credits",usedPercent:40,resetsAt:paceNow.addingTimeInterval(86400))) == nil,"주기 길이를 모르면 예측하지 않음")
        check(RunOut.span(25*3600+120) == "1일 1시간" && RunOut.span(5400) == "1시간 30분" && RunOut.span(20) == "1분","남은 시간 문구")
        check(DateFormats.formatter("HH:mm") === DateFormats.formatter("HH:mm"),"날짜 형식기를 다시 만들지 않음")
        let variantNow = Calendar.current.date(bySettingHour:20,minute:0,second:0,of:paceNow)!
        check(RunOut.variants(variantNow.addingTimeInterval(9.5*3600),now:variantNow) == ["내일 05:30 소진 예정","05:30 소진 예정","내일 소진 예정","소진 예정"] && RunOut.variants(variantNow.addingTimeInterval(3600),now:variantNow) == ["21:00 소진 예정","소진 예정"],"소진 예정 문구는 시각부터 줄이고 '소진 예정'은 남김")
        check(!RunOut.variants(variantNow.addingTimeInterval(27*3600),now:variantNow).contains("23:00 소진 예정") && RunOut.short(variantNow.addingTimeInterval(9.5*3600),now:variantNow) == "05:30" && RunOut.short(variantNow.addingTimeInterval(27*3600),now:variantNow) != "23:00","24시간 넘게 남으면 시각만 따로 쓰지 않음")
        let nine = NSFont.monospacedDigitSystemFont(ofSize:9,weight:.regular)
        func nineWidth(_ s:String)->CGFloat {(s as NSString).size(withAttributes:[.font:nine]).width}
        check(nineWidth("이번 주 수요일 00:00")+4+nineWidth("05:55 소진 예정")+1 <= MeterLayout.column(604,single:false),"기본 폭에서 리셋 시각 옆에 시각이 있는 소진 예정이 들어감")
        let nameFont = NSFont.systemFont(ofSize:10)
        check(("Claude Code · Max 20x" as NSString).size(withAttributes:[.font:nameFont]).width+30 <= 604-80-48-18-2*MeterLayout.column(604,single:false),"계정 열에 가장 긴 설명이 들어감")
        var oldPrefs = try! JSONSerialization.jsonObject(with:JSONEncoder().encode(Preferences())) as! [String:Any];oldPrefs.removeValue(forKey:"showRunOut")
        check(Preferences.read(try! JSONSerialization.data(withJSONObject:oldPrefs))?.showRunOut == true,"기존 설정에는 소진 예상이 켜진 채로 추가")
        // Plan capacity: samples, Codex logs, Claude hours and work ranking.
        var book = CapacityBook();let bookNow = Date(timeIntervalSince1970:1_793_500_000)
        let firstReset = bookNow.addingTimeInterval(3*86400)
        check(book.record(id:"x",used:10,reset:firstReset,at:bookNow),"첫 주간 표본 저장")
        check(!book.record(id:"x",used:10.3,reset:firstReset,at:bookNow.addingTimeInterval(300)),"0.5%p 미만 변화는 표본을 늘리지 않음")
        check(book.record(id:"x",used:11,reset:firstReset,at:bookNow.addingTimeInterval(600)) && book.record(id:"x",used:0,reset:firstReset.addingTimeInterval(7*86400),at:bookNow.addingTimeInterval(900)),"사용 변화와 새 주기는 표본으로 남김")
        check(!book.record(id:"x",used:20,reset:firstReset,at:bookNow),"과거 시각 표본은 버림")
        var codexLog = CapacityEstimator.Codex()
        func codexLine(_ i:Int,used:Double,reset:Double)->Data {
            Data(#"{"timestamp":"t\#(i)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":\#(i*1100)},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":800,"output_tokens":100,"total_tokens":1100}},"rate_limits":{"primary":{"used_percent":\#(used),"window_minutes":10080,"resets_at":\#(reset)}}}}"#.utf8)
        }
        let logFile = FileManager.default.temporaryDirectory.appendingPathComponent("teum-capacity-\(UUID().uuidString).jsonl")
        var logText = Data()
        for i in 0..<40 {logText += codexLine(i,used:10+Double(i)*20/39,reset:1_793_600_000);logText.append(10)}
        logText += codexLine(39,used:30,reset:1_793_600_000);logText.append(10)
        for i in 100..<135 {logText += codexLine(i,used:50+Double(i-100)/20,reset:1_794_200_000);logText.append(10)}
        try? logText.write(to:logFile);codexLog.scan(file:logFile);try? FileManager.default.removeItem(at:logFile)
        let codexEstimate = codexLog.estimate(now:bookNow)
        check(codexEstimate.windows == 1 && abs((codexEstimate.tokensPerPoint ?? 0)-1360)<0.5,"코덱스 로그로 1%p당 환산 토큰 계산(중복·작은 변화 제외)")
        var claudeCache = TokenHistoryCache()
        let claudeDay = Calendar.current.startOfDay(for:bookNow),claudeKey = UsageArchive.dayKey(claudeDay)
        var hours = Array(repeating:0,count:24);hours[10] = 1_000_000
        claudeCache.projects.days[claudeKey] = ["p":[CostSource.claudeCode.rawValue:["cli":ProjectDay(hours:hours)]]]
        claudeCache.archive.days[claudeKey] = [CostSource.claudeCode.rawValue:["m":ArchiveEntry(input:100_000,output:100_000,cacheRead:800_000)]]
        claudeCache.projects.lastScan = claudeDay.addingTimeInterval(12*3600)
        let claudeSamples = [CapacitySample(t:claudeDay.addingTimeInterval(10*3600).timeIntervalSince1970,used:10,reset:2e9),CapacitySample(t:claudeDay.addingTimeInterval(11*3600).timeIntervalSince1970,used:20,reset:2e9),CapacitySample(t:claudeDay.addingTimeInterval(13*3600).timeIntervalSince1970,used:30,reset:2e9)]
        let claudeEstimate = CapacityEstimator.claude(samples:claudeSamples,cache:claudeCache,now:bookNow)
        check(abs((claudeEstimate.tokensPerPoint ?? 0)-58_000)<1,"클로드는 시간별 토큰과 Teum 주간 표본으로 계산(기록 이후 구간 제외)")
        check(CapacityEstimator.claude(samples:Array(claudeSamples.prefix(1)),cache:claudeCache,now:bookNow).tokensPerPoint == nil,"표본이 부족하면 추정하지 않음")
        check(claudeEstimate.points == 10 && !claudeEstimate.lowConfidence && CapacityEstimate(tokensPerPoint:1,points:4,method:"t",measuredAt:bookNow).lowConfidence,"10%p 미만 추정은 표본 적음으로 표시")
        var workPrefs = Preferences()
        func workReading(_ left:Double,days:Double)->Reading {Reading(snapshot:UsageSnapshot(windows:[UsageWindow(title:"Weekly window",usedPercent:100-left,resetsAt:bookNow.addingTimeInterval(days*86400),windowSeconds:604800)],fetchedAt:bookNow))}
        let workReadings = ["claude":workReading(80,days:2),"codex":workReading(50,days:1),"agy-claude":workReading(90,days:3)]
        let workSizes = ["claude":1_000_000.0,"codex":500_000.0]
        check(QuotaPlanner.build(prefs:workPrefs,readings:workReadings,now:bookNow,capacity:workSizes).accounts.map(\.id) == ["codex","claude","agy-claude"],"기본은 계정별 %p 순서")
        workPrefs.planBasis = "work"
        let workPlan = QuotaPlanner.build(prefs:workPrefs,readings:workReadings,now:bookNow,capacity:workSizes)
        check(workPlan.accounts.map(\.id) == ["claude","codex","agy-claude"] && workPlan.basis == "work","일하는 양 기준은 환산 토큰 순, 추정 없는 계정은 뒤")
        check(abs((workPlan.accounts.first?.workPressure(now:bookNow) ?? 0)-35_000_000)<1,"하루 환산 토큰 = %p 압력 × 1%p 크기")
        workPrefs.planPriority = ["agy-claude"]
        check(QuotaPlanner.build(prefs:workPrefs,readings:workReadings,now:bookNow,capacity:workSizes).accounts.first?.id == "agy-claude","선호 AI는 일하는 양보다 앞")
        let deferredTokens = TokenHistoryStore(directory:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),deferred:true)
        check(deferredTokens.openingCache && !deferredTokens.hasData,"페이지 진입 전 동기 파일 읽기 없이 로딩 상태 준비")
        let sampleTokens = TokenHistoryStore.sample();let weekTokens = TokenHistoryStore.report(sampleTokens,period:.week)
        check(weekTokens.total.allTokens == weekTokens.models.reduce(0){$0+$1.entry.allTokens},"모델별 토큰 합계와 전체 일치")
        check(weekTokens.total.allTokens == weekTokens.daily.reduce(0){$0+$1.tokens},"일별 토큰 합계와 전체 일치")
        check(TokenHistoryStore.report(sampleTokens,period:.today).daily.count == 1,"오늘 필터는 현재 로컬 날짜만")
        let legacyDir = FileManager.default.temporaryDirectory.appendingPathComponent("Teum-archive-test-"+UUID().uuidString)
        try! FileManager.default.createDirectory(at:legacyDir,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:legacyDir)}
        var legacyArchive = UsageArchive();var imported = TokenHistoryCache()
        let olderDay = UsageArchive.dayKey(Calendar.current.date(byAdding:.day,value:-60,to:.now)!)
        let firstDay = UsageArchive.dayKey(Calendar.current.date(byAdding:.day,value:-150,to:.now)!)
        legacyArchive.days = [olderDay:["claudeCode":["fixture":ArchiveEntry(input:500)]],firstDay:["claudeCode":["fixture":ArchiveEntry(input:200)]]]
        let legacyEncoder = JSONEncoder();legacyEncoder.dateEncodingStrategy = .secondsSince1970
        let legacyBytes = try! legacyEncoder.encode(legacyArchive),legacyFile = legacyDir.appendingPathComponent("usage-archive.json")
        try! legacyBytes.write(to:legacyFile)
        imported.archive.days[olderDay] = ["claudeCode":["fixture":ArchiveEntry(input:700)]]
        imported.importArchive(directory:legacyDir)
        let once = imported.archive.days
        imported.importArchive(directory:legacyDir)
        check(imported.archive.days == once && imported.archive.days[olderDay]?["claudeCode"]?["fixture"]?.input == 700,"보관 집계는 큰 값만 유지해 반복 가져오기 중복 방지")
        check(TokenHistoryStore.report(imported,period:.quarter).total.allTokens == 700 && TokenHistoryStore.report(imported,period:.quarter).daily.count == 90,"90일 조회에 60일 전 보관 기록 포함")
        check(TokenHistoryStore.report(imported,period:.all).total.allTokens == 900,"전체 조회는 150일 전 기록도 포함")
        check(imported.archive.lastScan == nil && (try! Data(contentsOf:legacyFile)) == legacyBytes,"가져오기는 조회 신선도와 원본 파일을 변경하지 않음")
        let logHome = FileManager.default.temporaryDirectory.appendingPathComponent("Teum-log-test-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:logHome)}
        let logA = logHome.appendingPathComponent("personal"),logB = logHome.appendingPathComponent("work")
        try! FileManager.default.createDirectory(at:logA,withIntermediateDirectories:true)
        try! FileManager.default.createDirectory(at:logB,withIntermediateDirectories:true)
        let stamp = ISO8601DateFormatter().string(from:.now)
        func log(_ id:String,input:Int,output:Int,cached:Int)->Data {
            let rows:[[String:Any]] = [
                ["type":"session_meta","payload":["id":id,"cwd":"/tmp/teum-fixture","originator":"codex_cli_rs"]],
                ["type":"turn_context","payload":["model":"fixture-model"]],
                ["type":"event_msg","timestamp":stamp,"payload":["type":"token_count","info":["last_token_usage":["input_tokens":input,"output_tokens":output,"cached_input_tokens":cached]]]]
            ]
            return rows.reduce(into:Data()){data,row in data.append(try! JSONSerialization.data(withJSONObject:row));data.append(10)}
        }
        let first = log("session-a",input:1000,output:100,cached:400)
        try! first.write(to:logA.appendingPathComponent("rollout-a.jsonl"))
        try! first.write(to:logB.appendingPathComponent("rollout-copy.jsonl"))
        try! log("session-b",input:2000,output:200,cached:800).write(to:logB.appendingPathComponent("rollout-b.jsonl"))
        let scanPaths = CostPaths(claudeProjects:logHome.appendingPathComponent("absent"),codexSessions:logA,additionalCodexSessions:[logB,logA],openCodeDatabase:logHome.appendingPathComponent("absent.db"))
        let scan = CostEstimator.archiveScan(paths:scanPaths,since:.now.addingTimeInterval(-3600))
        var scanned = TokenHistoryCache();scanned.archive.merge(scan.days,scannedAt:.now,full:true)
        let parsedTokens = TokenHistoryStore.report(scanned,period:.today)
        check(parsedTokens.total.allTokens == 3300,"복수 코덱스 경로와 복제 세션 중복 제거")
        check(parsedTokens.total.input == 1800 && parsedTokens.total.cacheRead == 1200,"코덱스 입력에 포함된 캐시는 이중 집계하지 않음")
        scanned.projects.merge(scan.projects,infos:scan.projectRefs,scannedAt:.now,full:true)
        let hourlyTokens = TokenHistoryStore.report(scanned,period:.today)
        check(hourlyTokens.hourly.count == 24 && hourlyTokens.hourly.reduce(0){$0+$1.tokens} == 3300,"오늘24시간의 실제 로그 토큰 합계 일치")
        check(hourlyTokens.hourly[Calendar.current.component(.hour,from:.now)].tokens == 3300,"로그 발생 시각의 시간대에 토큰 집계")
        let resetNow = Date();let soonReset = resetNow.addingTimeInterval(30)
        let resetSnapshot = UsageSnapshot(windows:[UsageWindow(title:"short",resetsAt:soonReset)],fetchedAt:resetNow)
        check(WindowLogic.nextResetCheck([resetSnapshot],now:resetNow) == soonReset.addingTimeInterval(1),"리셋1초후 전체 재조회 예약")
        var missedReset = resetSnapshot;missedReset.windows[0].resetsAt = resetNow.addingTimeInterval(-20);missedReset.fetchedAt = resetNow.addingTimeInterval(-60)
        check(WindowLogic.nextResetCheck([missedReset],now:resetNow) == resetNow.addingTimeInterval(10),"리셋 직후 실패한 조회는10초후 재확인")
        missedReset.windows[0].resetsAt = resetNow.addingTimeInterval(-120);missedReset.fetchedAt = resetNow.addingTimeInterval(-180)
        check(WindowLogic.nextResetCheck([missedReset],now:resetNow) == nil,"오래된 리셋은 무한 재조회 금지")
        var boundaryPrefs = Preferences();boundaryPrefs.streams = [Stream.defaults[0]]
        let oldBoundary = Date().addingTimeInterval(-2)
        let beforeBoundary = UsageSnapshot(windows:[UsageWindow(title:"short",usedPercent:0,resetsAt:oldBoundary)],fetchedAt:oldBoundary.addingTimeInterval(-60))
        let afterBoundary = UsageSnapshot(windows:[UsageWindow(title:"short",usedPercent:0,resetsAt:oldBoundary.addingTimeInterval(18000))],fetchedAt:.now)
        var boundaryEngine = NoticeEngine(previous:["claude":beforeBoundary])
        check(boundaryEngine.events(prefs:boundaryPrefs,readings:["claude":Reading(snapshot:afterBoundary)]).first?.kind == .reset,"100% 유지여도 서버의 새 주기 확인 시 리셋 알림")
        var delayedEngine = NoticeEngine(previous:["claude":beforeBoundary])
        var delayed = beforeBoundary;delayed.fetchedAt = Date().addingTimeInterval(-1)
        let premature = delayedEngine.events(prefs:boundaryPrefs,readings:["claude":Reading(snapshot:delayed)])
        check(premature.isEmpty && delayedEngine.events(prefs:boundaryPrefs,readings:["claude":Reading(snapshot:afterBoundary)]).first?.kind == .reset,"서버 지연 응답은 알리지 않고 실제 주기 변경 확인 후 한 번 알림")
        var providerBefore = afterBoundary;providerBefore.fetchedAt = Date().addingTimeInterval(-60);providerBefore.windows[0].usedPercent = 80
        var providerEngine = NoticeEngine(previous:["claude":providerBefore])
        let providerRecovery = providerEngine.events(prefs:boundaryPrefs,readings:["claude":Reading(snapshot:afterBoundary)])
        check(providerRecovery.first?.kind == .recovery,"예정 시각 전 업체의 한도 회복도 실제 서버 값으로 알림")
        check(providerEngine.events(prefs:boundaryPrefs,readings:["claude":Reading(snapshot:afterBoundary)]).isEmpty,"업체의 임의 회복 알림 중복 방지")
        let codex = store.readings["codex"]!.windows
        check(WindowLogic.horizon(codex,short:true) == nil,"주간 계정에 5시간 임의 생성 없음")
        check(WindowLogic.remaining(UsageWindow(title:"a",usedPercent:70)) == 30,"사용량을 잔여량으로 변환")
        check(WindowLogic.remaining(UsageWindow(title:"a")) == nil,"미확인 값 0 처리 금지")
        check(WindowLogic.resetText(.now.addingTimeInterval(-1)).contains("확인"),"리셋 시각 경과 표시")
        let old = store.prefs.streams.map(\.id);store.move("kiro",by:-1)
        check(store.prefs.streams[3].id == "kiro" && Set(old) == Set(store.prefs.streams.map(\.id)),"순서 이동 계정 보존")
        let json = try! JSONEncoder().encode(store.prefs)
        check((try! JSONDecoder().decode(Preferences.self,from:json)) == store.prefs,"설정 전체 왕복")
        let agy = Stream.defaults[2]
        let windows = [UsageWindow(title:"5-hour · Gemini",scope:"Gemini"),UsageWindow(title:"5-hour · Claude and GPT",scope:"Claude and GPT")]
        check(QuotaStore.filtered(windows,for:agy).count == 1 && QuotaStore.filtered(windows,for:agy)[0].scope == "Claude and GPT","AGY 그룹 분리")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("Teum-test-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:temp)}
        let isolated = QuotaStore(directory:temp,bootstrapLegacy:false)
        isolated.prefs.streams[0].name = "검사용 클로드";isolated.prefs.streams[2].warns = false;isolated.save()
        let reload = QuotaStore(directory:temp,bootstrapLegacy:false)
        check(reload.prefs.streams[0].name == "검사용 클로드" && !reload.prefs.streams[2].warns,"격리 저장과 재시작 복원")
        let attrs = try! FileManager.default.attributesOfItem(atPath:temp.appendingPathComponent("settings.json").path)
        check((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600,"설정 파일 권한")
        let oldReset = UsageWindow(title:"old",usedPercent:90,resetsAt:Date().addingTimeInterval(-3))
        check(WindowLogic.expired(oldReset,snapshot:UsageSnapshot(fetchedAt:Date().addingTimeInterval(-60))),"오래된 리셋 판별")
        let legacy = Data("{\"wingWidth\":92,\"notchEnabled\":true}".utf8)
        check(Preferences.read(legacy)?.wingWidth == 92 && Preferences.read(legacy)?.notchEnabled == true && Preferences.read(legacy)?.cameraWidth == 184,"설정 추가 시 기존 값 보존")
        check(NotchLayout.cameraGap(Preferences(),detected:0) == 196,"가상 화면의 카메라 영역 확보")
        var numeric = Preferences();numeric.notchStyle = "allNumbers"
        check(NotchLayout.wing(numeric,count:7) >= 4*28+3*4,"전체 숫자 7개 폭 확보")
        let ordered = QuotaStore.fixture();ordered.prefs.notchStyle = "mixed"
        ordered.move("codex",by:-1)
        check(ordered.numberStreams.map(\.id) == ["codex","claude"],"계정 정렬이 숫자 앞 두 개에 즉시 반영")
        ordered.prefs.streams[0].pinned = false
        check(ordered.numberStreams.first?.id == "claude","노치에서 제외하면 다음 계정이 숫자로 이동")
        ordered.prefs.notchStyle = "fourNumbers"
        check(ordered.numberStreams.count == 4 && ordered.numberStreams.first?.id == "claude","숫자4개는 노치 대상 순서의 앞 네 계정")
        let fourWings = NotchLayout.wings(ordered.prefs,count:ordered.pinned.count)
        check(fourWings.left == 94 && fourWings.right == 94,"숫자4개 양쪽 두 자리와 세 자리 값 여백")
        check(NotchLayout.wings(ordered.prefs,count:2).left == 58 && NotchLayout.wings(ordered.prefs,count:2).right == 58,"숫자4개 모드의 계정 부족 시 좌우 균형")
        ordered.prefs.notchStyle = "bars"
        check(ordered.numberStreams.isEmpty,"막대 모드에서 숫자 배지 미표시")
        numeric.notchStyle = "compactNumbers"
        check(NotchLayout.wing(numeric,count:7) == 58,"두 숫자 모드 지정 여백 확보")
        check(Stream.color("#79C2E8") != nil && Stream.color("invalid") == nil,"사용자 색 형식 검증")
        let moment = Date()
        let resetWindow = UsageWindow(title:"5-hour window",usedPercent:90,resetsAt:moment.addingTimeInterval(-10))
        let oldNotice = UsageSnapshot(windows:[resetWindow],fetchedAt:moment.addingTimeInterval(-300))
        let freshNotice = UsageSnapshot(windows:[UsageWindow(title:"5-hour window",usedPercent:0,resetsAt:moment.addingTimeInterval(18000))],fetchedAt:moment)
        var engine = NoticeEngine(previous:["claude":oldNotice])
        let eventPrefs = Preferences()
        check(engine.events(prefs:eventPrefs,readings:["claude":Reading(snapshot:freshNotice)]).first?.kind == .reset,"새 서버 값으로만 리셋 알림")
        check(engine.events(prefs:eventPrefs,readings:["claude":Reading(snapshot:freshNotice)]).isEmpty,"같은 리셋 알림 중복 방지")
        var lowEngine = NoticeEngine()
        let lowValue = UsageSnapshot(windows:[UsageWindow(title:"5-hour window",usedPercent:100)],fetchedAt:moment)
        check(lowEngine.events(prefs:eventPrefs,readings:["claude":Reading(snapshot:lowValue)]).first?.kind == .empty,"새로 확인된 0% 소진 알림")
        var ignoredPrefs = eventPrefs;ignoredPrefs.streams[0].notifyLow = false
        var ignoredEngine = NoticeEngine()
        check(ignoredEngine.events(prefs:ignoredPrefs,readings:["claude":Reading(snapshot:lowValue)]).isEmpty,"계정별 노치 부족 알림 제외")
        ignoredPrefs = eventPrefs;ignoredPrefs.streams[0].ignoredWindows = [lowValue.windows[0].id]
        ignoredEngine = NoticeEngine()
        check(ignoredEngine.events(prefs:ignoredPrefs,readings:["claude":Reading(snapshot:lowValue)]).isEmpty,"한도별 노치 알림 제외")
        var staleEngine = NoticeEngine()
        check(staleEngine.events(prefs:eventPrefs,readings:["claude":Reading(snapshot:lowValue,error:"offline")]).isEmpty,"실패한 값으로 알림 금지")
        var targetPrefs = Preferences();targetPrefs.lowNotices = false;targetPrefs.paceNotices = true;targetPrefs.goalNearNotices = true;targetPrefs.goalReachedNotices = true
        let targetReset = moment.addingTimeInterval(302400)
        func targetSnapshot(_ used:Double,_ offset:Double)->UsageSnapshot {UsageSnapshot(windows:[UsageWindow(title:"weekly",usedPercent:used,resetsAt:targetReset,windowSeconds:604800)],fetchedAt:moment.addingTimeInterval(offset))}
        var paceEngine = NoticeEngine(previous:["claude":targetSnapshot(40,-10)])
        check(paceEngine.events(prefs:targetPrefs,readings:["claude":Reading(snapshot:targetSnapshot(60,-3))]).first?.kind == .pace,"균등 기준 하향 돌파 시 아일랜드 알림")
        check(paceEngine.events(prefs:targetPrefs,readings:["claude":Reading(snapshot:targetSnapshot(61,-2))]).isEmpty,"같은 주기 사용 속도 알림 반복 금지")
        var disabledTarget = targetPrefs;disabledTarget.paceNotices = false
        var silentPace = NoticeEngine(previous:["claude":targetSnapshot(40,-10)])
        check(silentPace.events(prefs:disabledTarget,readings:["claude":Reading(snapshot:targetSnapshot(60,-3))]).isEmpty,"균등 기준 알림 끄기")
        var goalsEngine = NoticeEngine()
        var targetDay = DailyGoalDay(targets:["claude":10],used:["claude":7],startedAt:moment.addingTimeInterval(-100))
        _ = goalsEngine.events(prefs:targetPrefs,readings:["claude":Reading(snapshot:targetSnapshot(30,-4))],goals:targetDay)
        targetDay.used["claude"] = 8.5
        let nearGoal = goalsEngine.events(prefs:targetPrefs,readings:["claude":Reading(snapshot:targetSnapshot(31,-3))],goals:targetDay).first
        check(nearGoal?.kind == .goalNear && nearGoal?.remaining == 15,"오늘 목표 남은15% 근접 알림과 단위")
        check(goalsEngine.events(prefs:targetPrefs,readings:["claude":Reading(snapshot:targetSnapshot(31,-3))],goals:targetDay).isEmpty,"같은 목표 snapshot 재처리 금지")
        targetDay.used["claude"] = 10.5
        check(goalsEngine.events(prefs:targetPrefs,readings:["claude":Reading(snapshot:targetSnapshot(33,-2))],goals:targetDay).first?.kind == .goalReached,"목표 도달·초과 시 별도 알림")
        targetDay.used["claude"] = 12
        check(goalsEngine.events(prefs:targetPrefs,readings:["claude":Reading(snapshot:targetSnapshot(34,-1))],goals:targetDay).isEmpty,"목표 초과 상태 반복 알림 금지")
        var editEngine = NoticeEngine()
        targetDay.used["claude"] = 7;targetDay.targets["claude"] = 10
        _ = editEngine.events(prefs:targetPrefs,readings:["claude":Reading(snapshot:targetSnapshot(30,-4))],goals:targetDay)
        targetDay.targets["claude"] = 5
        check(editEngine.events(prefs:targetPrefs,readings:["claude":Reading(snapshot:targetSnapshot(31,-3))],goals:targetDay).isEmpty,"목표 수치 편집만으로 소비 알림 금지")
        var firstUseEngine = NoticeEngine()
        targetDay.targets["claude"] = 10;targetDay.used = [:]
        _ = firstUseEngine.events(prefs:targetPrefs,readings:["claude":Reading(snapshot:targetSnapshot(30,-4))],goals:targetDay)
        targetDay.used["claude"] = 8.5
        check(firstUseEngine.events(prefs:targetPrefs,readings:["claude":Reading(snapshot:targetSnapshot(31,-3))],goals:targetDay).first?.kind == .goalNear,"첫 사용도0을 기준으로 목표 근접 감지")
        let scopeFile = legacyDir.appendingPathComponent("scope.json")
        let scopeDate = Calendar.current.date(byAdding:.day,value:-120,to:moment)!
        let scopeRows:[[String:Any]] = [["dayStart":scopeDate.timeIntervalSinceReferenceDate,"model":"fixture-scope","source":"codexLocalSessionLog","isLegacyUnverified":false,"usage":["inputTokens":1000,"outputTokens":100,"cachedInputTokens":600,"totalTokens":1100]], ["dayStart":scopeDate.timeIntervalSinceReferenceDate,"model":"unverified","source":"claudeLocalProjectLog","isLegacyUnverified":true,"usage":["inputTokens":9000,"outputTokens":100,"totalTokens":9100]]]
        try! JSONSerialization.data(withJSONObject:scopeRows).write(to:scopeFile)
        var scopeCache = TokenHistoryCache();scopeCache.importUsageScope(file:scopeFile);scopeCache.importUsageScope(file:scopeFile)
        let scopeEntry = scopeCache.archive.days[UsageArchive.dayKey(scopeDate)]?["codexCLI"]?["fixture-scope"]
        check(scopeEntry?.allTokens == 1100 && scopeEntry?.input == 400 && scopeEntry?.cacheRead == 600,"UsageScope 보관 수입은 캐시·중복 이중 집계 금지")
        check(scopeCache.archive.days[UsageArchive.dayKey(scopeDate)]?["claudeCode"] == nil,"미검증 UsageScope 집계는 제외")
        let scopeMonth = String(UsageArchive.dayKey(scopeDate).prefix(7))
        check(TokenHistoryStore.report(scopeCache,period:.week,month:scopeMonth).total.allTokens == 1100,"월별 필터로 이전 내역 조회")
        print(failures.isEmpty ? "PASS: \(count)개 핵심 동작 검사" : "FAIL: "+failures.joined(separator:", "))
        return failures.isEmpty
    }
}

@MainActor enum CLICollector {
    struct Output:Encodable {var schemaVersion = 1;var attemptedAt:Double;var snapshots:[String:UsageSnapshot];var errors:[String:String];var streamNames:[String:String]}
    static func run() async {
        var snapshots:[String:UsageSnapshot] = [:];var errors:[String:String] = [:]
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Teum")
        let streams = (try? Data(contentsOf:directory.appendingPathComponent("settings.json"))).flatMap(Preferences.read)?.streams ?? CodexProfiles.initial().streams
        let enabled = streams.filter{$0.connected != false}
        for s in streams where s.connected == false {errors[s.id] = "Teum 연결 해제됨"}
        var seen = Set<String>()
        let sources = enabled.filter{seen.insert($0.source == "agy" ? "agy" : $0.id).inserted}
        await withTaskGroup(of:(Stream,UsageSnapshot?,String?).self) {group in
            for s in sources {group.addTask {
                do{return(s,try await Collector.fetch(s,directory:directory),nil)}
                catch{return(s,nil,Collector.message(error,source:s.source))}
            }}
            for await (stream,value,error) in group {
                let targets = stream.source == "agy" ? enabled.filter{$0.source == "agy"} : [stream]
                for target in targets {
                    if var value {value.windows = QuotaStore.filtered(value.windows,for:target);snapshots[target.id] = value}
                    else {errors[target.id] = error ?? "조회 실패"}
                }
            }
        }
        let encoder = JSONEncoder();encoder.dateEncodingStrategy = .secondsSince1970
        let result = Output(attemptedAt:Date().timeIntervalSince1970,snapshots:snapshots,errors:errors,streamNames:Dictionary(uniqueKeysWithValues:streams.map{($0.id,$0.name)}))
        if let data = try? encoder.encode(result) {print(String(decoding:data,as:UTF8.self))}
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
