import AppKit

/// The first visible, connected account in Settings order, independent of notch pins.
@MainActor struct MenuBarUsage {
    let text: String
    let help: String
    let image: NSImage

    init(store: QuotaStore) {
        let stream = store.prefs.streams.first { $0.visible && $0.connected != false }
        let reading = stream.flatMap { store.readings[$0.id] }
        // Reuse the configured quota window; hiding a notch value must not hide the menu value.
        let window = stream.flatMap {
            WindowLogic.selected(reading?.windows ?? [], choice: $0.notchWindow == "none" ? "auto" : $0.notchWindow)
        }
        let remaining = window.flatMap(WindowLogic.remaining)
        let stale = reading?.stale(minutes: store.prefs.refreshMinutes) != false ||
            (window.map { WindowLogic.expired($0, snapshot: reading?.snapshot) } ?? false)
        text = remaining.map { "\(Int($0.rounded()))%" } ?? "—"
        let state = remaining == nil ? "사용량 미확인" : stale ? "마지막 확인 값" : "남은 사용량"
        help = "Teum · \(stream?.name ?? "계정 연결 필요") · \(state) \(text)" +
            (window.map { " · \(WindowLogic.label($0)) · 리셋 \(WindowLogic.exact($0.resetsAt))" } ?? "")
        image = Self.icon(remaining: remaining, stale: stale)
    }

    static func icon(remaining: Double?, stale: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            let rect = NSRect(x: 1.5, y: 1.5, width: 17, height: 17)
            NSColor.black.withAlphaComponent(0.24).setStroke()
            let track = NSBezierPath(ovalIn: rect);track.lineWidth = 1.5;track.stroke()
            if let remaining, remaining > 0 {
                NSColor.black.withAlphaComponent(stale ? 0.5 : 1).setStroke()
                let arc = NSBezierPath();arc.lineWidth = 1.5;arc.lineCapStyle = .round
                arc.appendArc(withCenter: NSPoint(x: 10, y: 10), radius: 8.5,
                              startAngle: 90, endAngle: 90 - CGFloat(remaining) * 3.6, clockwise: true)
                arc.stroke()
            }
            let value = remaining.map { String(Int($0.rounded())) } ?? "—"
            let number = NSAttributedString(string: value, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: value.count > 2 ? 7 : 8, weight: .semibold),
                .foregroundColor: NSColor.black.withAlphaComponent(stale ? 0.5 : 1)
            ])
            let size = number.size()
            number.draw(at: NSPoint(x: (20 - size.width) / 2, y: (20 - size.height) / 2))
            return true
        }
        image.isTemplate = true
        return image
    }
}
