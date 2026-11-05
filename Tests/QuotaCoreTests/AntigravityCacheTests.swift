import Foundation
import QuotaModel
@testable import QuotaCore

@main struct AntigravityCacheTests {
    static func main() {
        let fetched = Date(timeIntervalSince1970: 1_793_520_850)
        let reset = fetched.addingTimeInterval(9)
        let cache = AntigravityCLI.Cache()
        let snapshot = UsageSnapshot(windows: [
            UsageWindow(title: "Gemini 5h", usedPercent: 17.094, resetsAt: reset),
            UsageWindow(title: "Gemini weekly", usedPercent: 28, resetsAt: fetched.addingTimeInterval(400_000))
        ], fetchedAt: fetched)
        cache.store(snapshot, now: fetched)
        precondition(cache.reading(now: reset.addingTimeInterval(-1)) != nil, "Reuse before reset")
        precondition(cache.reading(now: reset) == nil, "Invalidate at reset, not after TTL")
        precondition(cache.reading(now: fetched.addingTimeInterval(296)) == nil, "Next scheduled refresh must not reuse pre-reset value")

        var fresh = snapshot
        fresh.fetchedAt = reset.addingTimeInterval(1)
        fresh.windows[0].resetsAt = reset.addingTimeInterval(18_000)
        fresh.windows[0].usedPercent = 2.16
        cache.store(fresh, now: fresh.fetchedAt)
        precondition(cache.reading(now: fresh.fetchedAt.addingTimeInterval(299)) != nil, "Reuse the new cycle normally")
        precondition(cache.reading(now: fresh.fetchedAt.addingTimeInterval(300)) == nil, "TTL still applies")

        // A fresh server response can itself lag the boundary. The bounded
        // retry must reach the server again rather than wait out a new TTL.
        var delayed = snapshot
        delayed.fetchedAt = reset.addingTimeInterval(1)
        cache.store(delayed, now: delayed.fetchedAt)
        precondition(cache.reading(now: reset.addingTimeInterval(10)) == nil, "Delayed server response cannot block reset retries")
        print("PASS: AGY cache reset/TTL regression checks (6)")
    }
}
