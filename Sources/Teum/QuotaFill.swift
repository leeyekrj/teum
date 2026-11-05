import AppKit
import SwiftUI

/// The view keeps its allocated size. Only its child layer's width animates,
/// so revealing several meters does not drive SwiftUI layout every frame.
struct QuotaFill:NSViewRepresentable {
    var value:Double
    var tint:Color
    var delay:Double
    var animated:Bool
    func makeNSView(context:Context)->QuotaFillView {QuotaFillView()}
    func updateNSView(_ view:QuotaFillView,context:Context) {
        view.configure(value:value,color:NSColor(tint),delay:delay,animated:animated)
    }
}

@MainActor final class QuotaFillView:NSView {
    private let fill = CALayer()
    private var fraction:CGFloat = 0
    private var configured = false
    private var initial = true
    private var pendingChange = false
    private var animated = false
    private var delay:Double = 0
    override var isFlipped:Bool {true}
    override init(frame:NSRect) {
        super.init(frame:frame);wantsLayer = true
        fill.anchorPoint = CGPoint(x:0,y:0.5);fill.cornerCurve = .continuous
        layer?.addSublayer(fill)
    }
    convenience init() {self.init(frame:.zero)}
    required init?(coder:NSCoder) {fatalError("init(coder:) has not been implemented")}
    override func hitTest(_ point:NSPoint)->NSView? {nil}
    func configure(value:Double,color:NSColor,delay:Double,animated:Bool) {
        let next = CGFloat(max(0,min(100,value.isFinite ? value : 0)))/100
        let changed = configured && fraction != next
        let animationChanged = self.animated != animated
        fraction = next;self.delay = max(0,delay);self.animated = animated
        CATransaction.begin();CATransaction.setDisableActions(true);fill.backgroundColor = color.cgColor;CATransaction.commit()
        if !configured || changed || animationChanged {
            pendingChange = pendingChange || changed;needsLayout = true
        }
        configured = true
        if !animated {fill.removeAllAnimations()}
    }
    override func layout() {
        super.layout()
        guard configured,bounds.width>0,bounds.height>0 else{return}
        let from = initial ? CGFloat.zero : fill.presentation()?.bounds.width ?? fill.bounds.width
        let target = bounds.width*fraction
        let reveal = initial
        let shouldAnimate = animated && (reveal || pendingChange)
        CATransaction.begin();CATransaction.setDisableActions(true)
        fill.bounds = CGRect(x:0,y:0,width:target,height:bounds.height)
        fill.position = CGPoint(x:0,y:bounds.midY);fill.cornerRadius = bounds.height/2
        CATransaction.commit()
        if shouldAnimate {
            let animation = CABasicAnimation(keyPath:"bounds.size.width")
            animation.fromValue = from;animation.toValue = target
            animation.duration = reveal ? 0.65 : 0.35
            animation.beginTime = CACurrentMediaTime()+(reveal ? delay : 0)
            animation.fillMode = .backwards
            animation.timingFunction = reveal ? CAMediaTimingFunction(controlPoints:0.16,1,0.3,1) : CAMediaTimingFunction(name:.easeOut)
            fill.add(animation,forKey:"quota-fill")
        }
        initial = false;pendingChange = false
    }
}
