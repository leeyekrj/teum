import AppKit
import SwiftUI

private final class IslandSurfaceView:NSView {override var isFlipped:Bool {true}}

/// Lay the content out once. Core Animation morphs the silhouette on the compositor,
/// so a large SwiftUI table never has to lay out for each animation frame.
@MainActor final class IslandContainer:NSView {
    let header:NSView
    let detail:NSView
    let expandedSize:NSSize
    let surfaceSize:NSSize
    private let content = IslandSurfaceView()
    private let bowl = CAShapeLayer()
    private let contact = CAShapeLayer()
    let headerSize:NSSize
    let headerOffset:CGFloat
    let detailSize:NSSize
    let keepsCompactHeader:Bool
    private let silhouette = CAShapeLayer()
    private var tracking:NSTrackingArea?
    private var transitionGeneration = 0
    var entered:(()->Void)?
    var exited:(()->Void)?
    var reduceMotionOverride:Bool?
    override var isFlipped:Bool {true}
    override var fittingSize:NSSize {expandedSize}
    override var intrinsicContentSize:NSSize {expandedSize}
    var exportPath:CGPath? {silhouette.presentation()?.path ?? silhouette.path}
    var presentedBounds:CGRect { (silhouette.presentation()?.path ?? silhouette.path)?.boundingBoxOfPath ?? bounds }
    init(header:NSView,detail:NSView,width:CGFloat,headerSize:NSSize,headerOffset:CGFloat,detailSize:NSSize,keepsCompactHeader:Bool = false) {
        self.headerOffset = headerOffset;self.header = header;self.detail = detail;self.headerSize = headerSize;self.detailSize = detailSize
        self.keepsCompactHeader = keepsCompactHeader
        surfaceSize = NSSize(width:width,height:(keepsCompactHeader ? headerSize.height : 0)+detailSize.height)
        expandedSize = NSSize(width:width+64,height:surfaceSize.height+64)
        super.init(frame:NSRect(origin:.zero,size:expandedSize))
        wantsLayer = true;layer?.backgroundColor = NSColor.clear.cgColor
        bowl.fillColor = NSColor.black.cgColor;bowl.strokeColor = NSColor.white.withAlphaComponent(0.065).cgColor;bowl.lineWidth = 0.5
        bowl.shadowColor = NSColor.black.cgColor;bowl.shadowOpacity = 0.6;bowl.shadowRadius = 22;bowl.shadowOffset = CGSize(width:0,height:10)
        contact.fillColor = NSColor.black.cgColor;contact.shadowColor = NSColor.black.cgColor
        contact.shadowOpacity = 0.42;contact.shadowRadius = 5;contact.shadowOffset = CGSize(width:0,height:3)
        layer?.addSublayer(contact)
        layer?.addSublayer(bowl)
        content.wantsLayer = true;content.layer?.mask = silhouette;addSubview(content)
        content.addSubview(detail);content.addSubview(header)
        header.wantsLayer = true;detail.wantsLayer = true;header.layer?.opacity = keepsCompactHeader ? 1 : 0
        header.isHidden = !keepsCompactHeader
        autoresizingMask = [.width,.height]
    }
    required init?(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
    override func layout() {
        super.layout()
        header.frame = NSRect(x:(bounds.width-headerSize.width)/2+headerOffset,y:0,width:headerSize.width,height:headerSize.height)
        detail.frame = NSRect(x:(bounds.width-detailSize.width)/2,y:keepsCompactHeader ? headerSize.height : 0,width:detailSize.width,height:detailSize.height)
        content.frame = bounds;bowl.frame = bounds;contact.frame = bounds;silhouette.frame = bounds
        if silhouette.path == nil {let p = path(size:surfaceSize);silhouette.path = p;bowl.path = p;bowl.shadowPath = p;contact.path = p;contact.shadowPath = p}
    }
    private func path(size:NSSize)->CGPath {
        let x = (expandedSize.width-size.width)/2+(size.height <= headerSize.height ? headerOffset : 0)
        let w = size.width;let h = size.height
        let fraction = max(0,min(1,(h-headerSize.height)/max(1,surfaceSize.height-headerSize.height)))
        let top:CGFloat = fraction*10
        let r:CGFloat = min(h/2,9+fraction*15)
        let p = CGMutablePath()
        // Soft concave shoulders join the screen edge; the lower bowl stretches with it.
        p.move(to:CGPoint(x:x,y:0));p.addLine(to:CGPoint(x:x+w,y:0))
        p.addCurve(to:CGPoint(x:x+w-top,y:top),control1:CGPoint(x:x+w-top,y:0),control2:CGPoint(x:x+w-top,y:0))
        p.addLine(to:CGPoint(x:x+w-top,y:h-r))
        p.addCurve(to:CGPoint(x:x+w-top-r,y:h),control1:CGPoint(x:x+w-top,y:h-r*0.45),control2:CGPoint(x:x+w-top-r*0.45,y:h))
        p.addLine(to:CGPoint(x:x+top+r,y:h))
        p.addCurve(to:CGPoint(x:x+top,y:h-r),control1:CGPoint(x:x+top+r*0.45,y:h),control2:CGPoint(x:x+top,y:h-r*0.45))
        p.addLine(to:CGPoint(x:x+top,y:top))
        p.addCurve(to:CGPoint(x:x,y:0),control1:CGPoint(x:x+top,y:0),control2:CGPoint(x:x+top,y:0));p.closeSubpath()
        return p
    }
    func prepareCollapsed(from size:NSSize? = nil) {
        transitionGeneration += 1
        silhouette.removeAllAnimations();bowl.removeAllAnimations();contact.removeAllAnimations();detail.layer?.removeAllAnimations();header.layer?.removeAllAnimations()
        header.isHidden = false
        layoutSubtreeIfNeeded();displayIfNeeded()
        CATransaction.begin();CATransaction.setDisableActions(true)
        let p = path(size:size ?? headerSize);silhouette.path = p;bowl.path = p;bowl.shadowPath = p;detail.layer?.opacity = 0
        contact.path = p;contact.shadowPath = p;bowl.shadowOpacity = 0;contact.shadowOpacity = 0
        header.layer?.opacity = 1
        CATransaction.commit()
    }
    func transition(opening:Bool,completion:(()->Void)? = nil) {
        header.isHidden = false
        transitionGeneration += 1;let generation = transitionGeneration
        let target = path(size:opening ? surfaceSize : headerSize)
        let current = silhouette.presentation()?.path ?? silhouette.path ?? target
        let opacity = detail.layer?.presentation()?.opacity ?? detail.layer?.opacity ?? 1
        let compactOpacity = header.layer?.presentation()?.opacity ?? header.layer?.opacity ?? 1
        let translation = detail.layer?.presentation()?.value(forKeyPath:"transform.translation.y") as? CGFloat ?? 0
        let ambientOpacity = bowl.presentation()?.shadowOpacity ?? bowl.shadowOpacity
        let contactOpacity = contact.presentation()?.shadowOpacity ?? contact.shadowOpacity
        silhouette.removeAllAnimations();bowl.removeAllAnimations();contact.removeAllAnimations();detail.layer?.removeAllAnimations();header.layer?.removeAllAnimations()
        let reduced = reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let tempo = 1.18
        let duration = reduced ? 0.1 : (opening ? 0.6 : 0.42)*tempo
        CATransaction.begin();CATransaction.setDisableActions(true)
        silhouette.path = target;bowl.path = target;bowl.shadowPath = target;detail.layer?.opacity = opening ? 1 : 0
        contact.path = target;contact.shadowPath = target;bowl.shadowOpacity = opening ? 0.6 : 0;contact.shadowOpacity = opening ? 0.42 : 0
        header.layer?.opacity = keepsCompactHeader || !opening ? 1 : 0
        CATransaction.commit()
        if !reduced {
            // A small expansion rebound; a faster, critically damped return.
            // Both start at the presentation path when hover intent reverses.
            let morph = CASpringAnimation(keyPath:"path")
            // Retiming the physics as well as the duration preserves the rebound
            // while slowing the whole motion, rather than extending a dead tail.
            morph.mass = 1;morph.stiffness = (opening ? 310 : 650)/(tempo*tempo);morph.damping = (opening ? 26 : 51)/tempo
            morph.fromValue = current;morph.toValue = target;morph.duration = duration
            silhouette.add(morph,forKey:"island-morph");bowl.add(morph,forKey:"bowl-morph")
            let shadow = morph.copy() as! CAPropertyAnimation;shadow.keyPath = "shadowPath";bowl.add(shadow,forKey:"shadow-morph")
            contact.add(morph,forKey:"contact-morph");contact.add(shadow,forKey:"contact-shadow-morph")
        }
        for (layer,from,to) in [(bowl,ambientOpacity,Float(opening ? 0.6 : 0)),(contact,contactOpacity,Float(opening ? 0.42 : 0))] {
            let shade = CABasicAnimation(keyPath:"shadowOpacity");shade.fromValue = from;shade.toValue = to
            shade.duration = reduced ? 0.1 : duration;shade.timingFunction = CAMediaTimingFunction(name:.easeOut);layer.add(shade,forKey:"shadow-depth")
        }
        let fade = CABasicAnimation(keyPath:"opacity");fade.fromValue = opacity;fade.toValue = opening ? 1 : 0
        fade.duration = reduced ? 0.1 : (opening ? 0.22 : 0.12)*tempo
        fade.beginTime = CACurrentMediaTime()+(opening && !reduced ? 0.09*tempo : 0)
        fade.fillMode = .backwards;fade.timingFunction = CAMediaTimingFunction(name:.easeOut)
        detail.layer?.add(fade,forKey:"content-reveal")
        if !keepsCompactHeader {
            let dissolve = CABasicAnimation(keyPath:"opacity");dissolve.fromValue = compactOpacity;dissolve.toValue = opening ? 0 : 1
            dissolve.duration = reduced ? 0.1 : (opening ? 0.12 : 0.16)*tempo
            dissolve.beginTime = CACurrentMediaTime()+(!opening && !reduced ? 0.13*tempo : 0)
            dissolve.fillMode = .backwards;dissolve.timingFunction = CAMediaTimingFunction(name:.easeInEaseOut)
            header.layer?.add(dissolve,forKey:"compact-dissolve")
        }
        if opening && !reduced {
            let shift = CABasicAnimation(keyPath:"transform.translation.y");shift.fromValue = opacity < 0.01 ? -6 : translation;shift.toValue = 0
            shift.duration = 0.3*tempo;shift.beginTime = CACurrentMediaTime()+0.09*tempo;shift.fillMode = .backwards
            shift.timingFunction = CAMediaTimingFunction(controlPoints:0.16,1,0.3,1);detail.layer?.add(shift,forKey:"content-arrive")
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+duration) {[weak self] in
            guard let self,self.transitionGeneration == generation else{return}
            self.header.isHidden = opening && !self.keepsCompactHeader
            completion?()
        }
    }
    override func hitTest(_ point:NSPoint)->NSView? {
        // AppKit passes hitTest points in the receiver's superview space.
        // Child hitTest also expects its parent space, not its own bounds.
        let local = convert(point,from:superview)
        guard exportPath?.contains(local) == true else{return nil}
        if !keepsCompactHeader,header.layer?.opacity == 0 {return detail.hitTest(content.convert(local,from:self))}
        return super.hitTest(point)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas();if let tracking {removeTrackingArea(tracking)}
        // Shadow padding is transparent, and must not count as a hover surface.
        let surface = NSRect(x:(bounds.width-surfaceSize.width)/2,y:0,width:surfaceSize.width,height:surfaceSize.height)
        let a = NSTrackingArea(rect:surface,options:[.activeAlways,.mouseEnteredAndExited,.mouseMoved],owner:self,userInfo:nil)
        addTrackingArea(a);tracking = a
    }
    override func mouseMoved(with event:NSEvent){entered?()}
    override func mouseEntered(with event:NSEvent){entered?()}
    override func mouseExited(with event:NSEvent){exited?()}
}
