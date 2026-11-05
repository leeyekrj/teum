import AppKit

// Match Awake’s interruptible visibility curve, shared by opacity and position.
@MainActor final class MenuPanelAnimator {
    private var timer: Timer?
    var running: Bool { timer != nil }
    func stop() { timer?.invalidate(); timer = nil }
    static func eased(_ progress: Double) -> Double {
        // cubic-bezier(0.2, 0, 0, 1): quick response, gentle landing, no bounce.
        let x = min(1, max(0, progress))
        if x == 0 || x == 1 { return x }
        var low = 0.0, high = 1.0
        for _ in 0..<16 {
            let t = (low + high) / 2, u = 1 - t
            let sample = 3 * u * u * t * 0.2 + t * t * t
            if sample < x { low = t } else { high = t }
        }
        let t = (low + high) / 2
        return 3 * (1 - t) * t * t + t * t * t
    }
    func animate(from: Double, to: Double, duration: Double, update: @escaping (Double) -> Void, completion: @escaping () -> Void = {}) {
        stop()
        guard duration > 0, abs(from - to) > 0.0001 else { update(to); completion(); return }
        let started = ProcessInfo.processInfo.systemUptime
        let tick = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                let fraction = min(1, elapsed / duration)
                update(from + (to - from) * Self.eased(fraction))
                if fraction >= 1 { self.stop(); completion() }
            }
        }
        timer = tick
        RunLoop.main.add(tick, forMode: .common)
    }
}
