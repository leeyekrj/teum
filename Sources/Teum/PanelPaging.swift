import AppKit
import SwiftUI

enum PanelPages {
    static let titles = ["한도","사용 기록","오늘의 목표","배분 계획"]
    static func clamped(_ page:Int)->Int {max(0,min(titles.count-1,page))}
    static func next(_ page:Int,by step:Int)->Int {(clamped(page)+step%titles.count+titles.count)%titles.count}
}

/// Which page the panel shows. Kept out of QuotaStore so a page change only
/// redraws the panel chrome, never every view that observes the store.
@MainActor final class PanelNavigation:ObservableObject {
    @Published private(set) var page = 0
    /// +1 when the target page enters from the trailing edge.
    private(set) var direction = 1
    /// False for programmatic jumps, which snap without a slide.
    private(set) var animated = false
    func go(to target:Int,step:Int? = nil,animated:Bool = true) {
        let next = PanelPages.clamped(target);guard next != page else{return}
        direction = (step ?? next-page) >= 0 ? 1 : -1
        self.animated = animated
        page = next
    }
}

/// The account whose detail page 0 shows.
@MainActor final class PanelSelection:ObservableObject {
    @Published var account:String?
    /// The newest panel's selection, read by the offscreen click test.
    static weak var latest:PanelSelection?
    init(_ account:String? = nil) {self.account = account;Self.latest = self}
}

/// Hosts every page once. A page change adds Core Animation springs to the
/// page layers, so no SwiftUI view is rebuilt or laid out per frame and a
/// busy main thread cannot stall the slide.
struct PageCarousel:NSViewRepresentable {
    var page:Int
    var direction:Int
    var animated:Bool
    var make:(Int)->NSView
    var settled:(Int)->Void
    func makeNSView(context:Context)->PageStripView {
        let view = PageStripView(count:PanelPages.titles.count,initial:page,make:make)
        view.settled = settled
        return view
    }
    func updateNSView(_ view:PageStripView,context:Context) {
        view.settled = settled
        view.show(page,direction:direction,animated:animated)
    }
}

@MainActor final class PageStripView:NSView {
    private var hosts:[NSView?]
    private let make:(Int)->NSView
    private(set) var current:Int
    /// Resting x of every page that takes part in the slide, in page widths.
    private var slots:[Int:CGFloat]
    private var generation = 0
    private var attached = false
    private var sliding = false
    var settled:((Int)->Void)?
    var reduceMotionOverride:Bool?
    override var isFlipped:Bool {true}
    init(count:Int,initial:Int,make:@escaping (Int)->NSView) {
        hosts = Array(repeating:nil,count:count);self.make = make
        current = max(0,min(count-1,initial));slots = [current:0]
        super.init(frame:.zero)
        wantsLayer = true;layer?.masksToBounds = true
        mount(current)
    }
    required init?(coder:NSCoder) {fatalError("init(coder:) has not been implemented")}
    var mountedPages:[Int] {hosts.indices.filter{hosts[$0] != nil}}
    func pageView(_ page:Int)->NSView? {hosts.indices.contains(page) ? hosts[page] : nil}
    @discardableResult private func mount(_ page:Int)->NSView {
        if let view = hosts[page] {return view}
        let began = CACurrentMediaTime()
        let view = make(page)
        view.frame = NSRect(x:(slots[page] ?? 0)*bounds.width,y:0,width:bounds.width,height:bounds.height)
        view.isHidden = slots[page] == nil
        addSubview(view);hosts[page] = view
        if bounds.width>0 {view.layoutSubtreeIfNeeded()}
        SwipeTrace.record("page-mount",fields:["page":page,"ms":(CACurrentMediaTime()-began)*1000])
        return view
    }
    override func layout() {
        super.layout()
        for (page,view) in hosts.enumerated() {
            guard let view else{continue}
            view.frame = NSRect(x:(slots[page] ?? 0)*bounds.width,y:0,width:bounds.width,height:bounds.height)
            view.isHidden = slots[page] == nil
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil,!attached else{return}
        attached = true
        let page = current
        DispatchQueue.main.async {[weak self] in self?.settled?(page)}
        // Build the other pages once the panel has finished opening, one per
        // run-loop turn, so the first swipe never waits for a page to build.
        DispatchQueue.main.asyncAfter(deadline:.now()+0.9) {[weak self] in self?.prebuild()}
    }
    private func prebuild() {
        guard window != nil,let next = hosts.indices.first(where:{hosts[$0] == nil}) else{return}
        // Never build behind a slide in progress; the next swipe would wait for it.
        if sliding {DispatchQueue.main.asyncAfter(deadline:.now()+0.3) {[weak self] in self?.prebuild()};return}
        mount(next)
        DispatchQueue.main.asyncAfter(deadline:.now()+0.06) {[weak self] in self?.prebuild()}
    }
    private static func spring(_ keyPath:String,from:Any,to:Any)->CASpringAnimation {
        // Motion.navigate: spring(response 0.36, dampingFraction 0.9).
        let a = CASpringAnimation(keyPath:keyPath)
        a.mass = 1;a.stiffness = pow(2 * .pi/0.36,2);a.damping = 4 * .pi*0.9/0.36
        a.fromValue = from;a.toValue = to;a.duration = a.settlingDuration
        return a
    }
    func show(_ target:Int,direction:Int,animated:Bool) {
        guard target != current,hosts.indices.contains(target) else{return}
        let began = CACurrentMediaTime()
        let built = hosts[target] == nil
        let width = bounds.width
        mount(target)
        generation += 1;let generation = self.generation
        let reduced = reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animated,width>0,window != nil else {
            for view in hosts.compactMap({$0}) {view.layer?.removeAnimation(forKey:"page-slide");view.layer?.removeAnimation(forKey:"page-fade");view.alphaValue = 1}
            slots = [target:0];current = target;needsLayout = true;layoutSubtreeIfNeeded()
            settled?(target);return
        }
        var duration = 0.1
        CATransaction.begin();CATransaction.setDisableActions(true)
        if reduced {
            // No travel: the leaving pages fade out where they are.
            for (page,_) in slots where page != target {
                guard let view = hosts[page],let layer = view.layer else{continue}
                let from = layer.presentation()?.opacity ?? layer.opacity
                layer.removeAnimation(forKey:"page-slide");view.frame.origin.x = 0;slots[page] = 0
                view.alphaValue = 0
                let fade = CABasicAnimation(keyPath:"opacity");fade.fromValue = from;fade.toValue = 0;fade.duration = duration
                layer.add(fade,forKey:"page-fade")
            }
            if let view = hosts[target],let layer = view.layer {
                let from = slots[target] == nil ? 0 : layer.presentation()?.opacity ?? layer.opacity
                view.isHidden = false;view.frame.origin.x = 0;view.alphaValue = 1;slots[target] = 0
                let fade = CABasicAnimation(keyPath:"opacity");fade.fromValue = from;fade.toValue = 1;fade.duration = duration
                layer.add(fade,forKey:"page-fade")
            }
        } else {
            // Where every page on screen is right now, mid-slide included.
            var visual:[Int:CGFloat] = [:];var alpha:[Int:Float] = [:]
            for (page,slot) in slots {
                guard let layer = hosts[page]?.layer else{continue}
                visual[page] = slot+((layer.presentation()?.position.x ?? layer.position.x)-layer.position.x)/width
                alpha[page] = layer.presentation()?.opacity ?? layer.opacity
            }
            let start:CGFloat
            if let x = visual[target] {start = x}
            else {
                start = direction>0 ? (visual.values.max() ?? 0)+1 : (visual.values.min() ?? 0)-1
                visual[target] = start;alpha[target] = 0
            }
            // The pages move as one rigid strip, so they stay a page apart.
            var next:[Int:CGFloat] = [:]
            for (page,from) in visual {
                guard let view = hosts[page],let layer = view.layer else{continue}
                let to = (from-start).rounded()
                view.isHidden = false;view.frame.origin.x = to*width
                let toX = layer.position.x,fromX = toX+(from-to)*width
                let slide = Self.spring("position.x",from:fromX,to:toX)
                layer.add(slide,forKey:"page-slide")
                let opacity:Float = to == 0 ? 1 : 0
                view.alphaValue = CGFloat(opacity)
                layer.add(Self.spring("opacity",from:alpha[page] ?? 1,to:opacity),forKey:"page-fade")
                duration = slide.duration;next[page] = to
            }
            slots = next
        }
        CATransaction.commit()
        current = target;sliding = true
        SwipeTrace.record("page-slide",fields:["page":target,"built":built,"setupMs":(CACurrentMediaTime()-began)*1000,"reduced":reduced])
        DispatchQueue.main.asyncAfter(deadline:.now()+duration) {[weak self] in
            guard let self,self.generation == generation else{return}
            self.finish()
        }
    }
    private func finish() {
        for (page,view) in hosts.enumerated() where page != current {
            guard let view,!view.isHidden || slots[page] != nil else{continue}
            view.layer?.removeAnimation(forKey:"page-slide");view.layer?.removeAnimation(forKey:"page-fade")
            view.isHidden = true;view.alphaValue = 1
        }
        slots = [current:0];needsLayout = true;sliding = false
        SwipeTrace.record("page-settled",fields:["page":current])
        settled?(current)
    }
}

/// A physical scroll gesture may commit one page. Momentum can never commit.
struct PageSwipeGate {
    enum Phase {case began,changed,ended,cancelled,unphased}
    enum Axis {case undecided,horizontal,vertical}
    private var axis:Axis = .undecided
    private var x:CGFloat = 0
    private var y:CGFloat = 0
    private var committed = false
    private var last:TimeInterval = -.infinity
    mutating func feed(x dx:CGFloat,y dy:CGFloat,phase:Phase,momentum:Bool,time:TimeInterval,precise:Bool = true)->(step:Int?,consumed:Bool) {
        if momentum {return(nil,axis == .horizontal || abs(dx)>abs(dy))}
        if phase == .began || (phase == .unphased && time-last>0.45) {axis = .undecided;x = 0;y = 0;committed = false}
        last = time
        if phase == .cancelled {let consumed = axis == .horizontal;axis = .undecided;x = 0;y = 0;committed = false;return(nil,consumed)}
        x += dx;y += dy
        if axis == .undecided,max(abs(x),abs(y))>=12 {axis = abs(x)>abs(y)*1.4 ? .horizontal : .vertical}
        let consumed = axis == .horizontal
        var step:Int?
        if consumed,!committed,abs(x)>=(precise ? 16 : 42) {step = x<0 ? 1 : -1;committed = true}
        // Keep the latch until the next explicit began (or a quiet wheel burst).
        // Some devices report changed packets after ended and before momentum.
        return(step,consumed)
    }
}

struct PanelSwipeBridge:NSViewRepresentable {
    var turn:(Int)->Void
    func makeNSView(context:Context)->SwipeCaptureView {let v = SwipeCaptureView();v.turn = turn;return v}
    func updateNSView(_ view:SwipeCaptureView,context:Context) {view.turn = turn}
    static func dismantleNSView(_ view:SwipeCaptureView,coordinator:()) {view.stop()}
}

final class SwipeCaptureView:NSView {
    var turn:((Int)->Void)?
    private var monitor:Any?
    private var gate = PageSwipeGate()
    private var motionSeen = false
    private var lastInput:TimeInterval = -.infinity
    override func hitTest(_ point:NSPoint)->NSView? {nil}
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow();stop()
        guard window != nil else{return}
        monitor = NSEvent.addLocalMonitorForEvents(matching:.scrollWheel) {[weak self] event in
            guard let self,let window = self.window,event.window === window,window.isVisible else{return event}
            var ancestor:NSView? = self
            var island:IslandContainer?
            while let view = ancestor {if let found = view as? IslandContainer {island = found;break};ancestor = view.superview}
            if let island {
                guard island.presentedBounds.height>island.headerSize.height+10,island.presentedBounds.contains(island.convert(event.locationInWindow,from:nil)) else{return event}
            } else {guard self.bounds.contains(self.convert(event.locationInWindow,from:nil)) else{return event}}
            let shifted = !event.hasPreciseScrollingDeltas && event.modifierFlags.contains(.shift)
            let dx = shifted ? event.scrollingDeltaY : event.scrollingDeltaX
            let dy = shifted ? 0 : event.scrollingDeltaY
            let phase:PageSwipeGate.Phase = event.phase.contains(.began) ? .began : event.phase.contains(.cancelled) ? .cancelled : event.phase.contains(.ended) ? .ended : event.phase.isEmpty ? .unphased : .changed
            let momentum = !event.momentumPhase.isEmpty
            if !momentum {
                if phase == .began || event.timestamp-self.lastInput>0.45 {self.motionSeen = false}
                self.lastInput = event.timestamp
                if !self.motionSeen,max(abs(dx),abs(dy))>0 {
                    self.motionSeen = true
                    SwipeTrace.record("first-motion",fields:["eventAgeMs":max(0,(CACurrentMediaTime()-event.timestamp)*1000),"dx":Double(dx),"dy":Double(dy),"precise":event.hasPreciseScrollingDeltas])
                }
            }
            let result = self.gate.feed(x:dx,y:dy,phase:phase,momentum:momentum,time:event.timestamp,precise:event.hasPreciseScrollingDeltas)
            if let step = result.step {
                SwipeTrace.record("gesture-commit",fields:["step":step,"eventAgeMs":max(0,(CACurrentMediaTime()-event.timestamp)*1000)])
                let began = CACurrentMediaTime();self.turn?(step)
                SwipeTrace.record("callback-returned",fields:["elapsedMs":(CACurrentMediaTime()-began)*1000])
            }
            return result.consumed ? nil : event
        }
    }
    func stop() {if let monitor {NSEvent.removeMonitor(monitor)};monitor = nil}
    deinit {stop()}
}
