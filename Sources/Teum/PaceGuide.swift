import Foundation
import QuotaModel

enum PaceGuide {
    static func remaining(_ window:UsageWindow,now:Date = .now)->Double? {
        guard let reset = window.resetsAt,reset>now,WindowLogic.remaining(window) != nil,!window.extra else{return nil}
        let duration = window.windowSeconds.map(Double.init) ?? (QuotaPlanner.weekly(window) ? 604800 : 0)
        let left = reset.timeIntervalSince(now)
        guard duration>0,left<=duration else{return nil}
        return max(0,min(100,left/duration*100))
    }
    static func text(_ value:Double)->String {"고르게 썼다면 지금쯤 \(Int(value.rounded()))% 남아요"}
}
