import AppKit
import SwiftUI

/// Opt-in timing only: page indexes and event ages, never account/content data.
enum SwipeTrace {
    private static let file = ProcessInfo.processInfo.environment["TEUM_SWIPE_TRACE"].map{URL(fileURLWithPath:$0)}
    static var enabled:Bool {file != nil}
    private static let queue = DispatchQueue(label:"io.paul.teum.swipe-trace",qos:.utility)
    static func record(_ stage:String,fields:[String:Any] = [:]) {
        guard let file else{return}
        var row = fields;row["stage"] = stage;row["uptime"] = CACurrentMediaTime()
        guard var data = try? JSONSerialization.data(withJSONObject:row,options:.sortedKeys) else{return}
        data.append(10)
        let line = data
        queue.async {
            if !FileManager.default.fileExists(atPath:file.path) {
                FileManager.default.createFile(atPath:file.path,contents:Data(),attributes:[.posixPermissions:0o600])
            }
            guard let handle = try? FileHandle(forWritingTo:file) else{return}
            defer {try? handle.close()}
            if let size = try? handle.seekToEnd(),size>192*1024 {try? handle.truncate(atOffset:0);try? handle.seek(toOffset:0)}
            try? handle.write(contentsOf:line)
        }
    }
    static func flush() {if enabled {queue.sync {}}}
}

/// Trace-only: the longest gap between main-queue ticks after a page change.
/// A long gap is a main-thread stall that freezes SwiftUI-driven motion.
@MainActor enum StallProbe {
    private static var timer:DispatchSourceTimer?
    private static var started:CFTimeInterval = 0
    private static var last:CFTimeInterval = 0
    private static var maxGap = 0.0
    private static var over16 = 0
    private static var over33 = 0
    private static var stalled = 0.0
    private static var fields:[String:Any] = [:]
    static func watch(_ label:[String:Any],seconds:Double = 0.6) {
        guard SwipeTrace.enabled else{return}
        finish()
        fields = label;started = CACurrentMediaTime();last = started
        maxGap = 0;over16 = 0;over33 = 0;stalled = 0
        let source = DispatchSource.makeTimerSource(queue:.main)
        source.schedule(deadline:.now(),repeating:.milliseconds(2),leeway:.microseconds(500))
        source.setEventHandler {
            MainActor.assumeIsolated {
                let now = CACurrentMediaTime();let gap = (now-last)*1000
                maxGap = max(maxGap,gap)
                if gap>16.7 {over16 += 1;stalled += gap}
                if gap>33.4 {over33 += 1}
                last = now
                if now-started>=seconds {finish()}
            }
        }
        timer = source;source.resume()
    }
    static func finish() {
        guard let source = timer else{return}
        source.cancel();timer = nil
        var row = fields
        row["maxGapMs"] = maxGap;row["gapsOver16"] = over16;row["gapsOver33"] = over33;row["stalledMs"] = stalled
        SwipeTrace.record("stall-summary",fields:row)
    }
}

struct PageLayoutProbe:NSViewRepresentable {
    var page:Int
    func makeNSView(context:Context)->PageLayoutProbeView {PageLayoutProbeView()}
    func updateNSView(_ view:PageLayoutProbeView,context:Context) {view.setPage(page)}
}
final class PageLayoutProbeView:NSView {
    private var page = -1
    private var pending = false
    override func hitTest(_ point:NSPoint)->NSView? {nil}
    func setPage(_ page:Int) {
        guard self.page != page else{return}
        self.page = page;pending = true;needsLayout = true
        SwipeTrace.record("page-view-updated",fields:["page":page])
    }
    override func layout() {
        super.layout();guard pending else{return};pending = false
        let page = page;SwipeTrace.record("page-layout",fields:["page":page])
        DispatchQueue.main.async {SwipeTrace.record("page-next-runloop",fields:["page":page])}
    }
}
