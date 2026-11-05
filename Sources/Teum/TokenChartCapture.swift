import AppKit
import SwiftUI
import QuotaCore

// AppKit/SwiftUI renders of the shipping view, with isolated fixture state.
@MainActor enum TokenChartCapture {
    static func run(at path:String) {
        let out = URL(fileURLWithPath:path)
        try? FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        let sample = QuotaStore.fixture()
        func render(_ name:String,_ width:CGFloat = 604,selected:Date? = nil,hour:Int? = nil) {
            let view = TokenHistoryView(history:sample.tokenHistory,streams:sample.prefs.streams,initialDay:selected,initialHour:hour)
                .frame(width:width,height:520).background(.black).foregroundStyle(Ink.text).environment(\.colorScheme,.dark)
                .transaction {$0.animation = nil;$0.disablesAnimations = true}
            let host = NSHostingView(rootView:view)
            host.appearance = NSAppearance(named:.darkAqua)
            host.frame = NSRect(x:0,y:0,width:width,height:520)
            let window = NSWindow(contentRect:host.frame,styleMask:.borderless,backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false;window.contentView = host
            window.setFrameOrigin(NSPoint(x:-20000,y:-20000))
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until:Date().addingTimeInterval(0.10))
            Capture.native(host,to:out.appendingPathComponent(name+".png"))
            window.close()
            print("CAPTURE \(name)")
        }
        sample.tokenHistory.period = .week
        render("week")
        render("week-selected",selected:sample.tokenHistory.report().daily[4].day)
        render("week-narrow",560,selected:sample.tokenHistory.report().daily.first?.day)
        sample.tokenHistory.period = .today
        render("today");render("today-selected",hour:0);render("today-narrow",560,hour:23)
        sample.tokenHistory.period = .month;render("month")
        sample.tokenHistory.period = .quarter;render("quarter")
        let decoder = JSONDecoder();decoder.dateDecodingStrategy = .secondsSince1970
        if let i = CommandLine.arguments.firstIndex(of:"--history-cache"),i+1<CommandLine.arguments.count,
           let data = try? Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[i+1])),
           let cache = try? decoder.decode(TokenHistoryCache.self,from:data) {
            sample.tokenHistory.cache = cache
            sample.tokenHistory.period = .week
            render("live-week")
            render("live-week-selected",selected:sample.tokenHistory.report().daily[4].day)
            render("live-week-narrow",560,selected:sample.tokenHistory.report().daily.last?.day)
            sample.tokenHistory.period = .today
            render("live-today");render("live-today-selected",hour:0);render("live-today-narrow",560,hour:0)
            sample.tokenHistory.period = .month;render("live-month")
            sample.tokenHistory.period = .all;render("live-all")
        }
        // No artificial bar for a day with no saved usage. A single saved day
        // also retains a centred label, including the all-history range.
        sample.tokenHistory.cache = TokenHistoryCache()
        sample.tokenHistory.cache.archive.days[UsageArchive.dayKey(.now)] = [CostSource.codexCLI.rawValue:["sample":ArchiveEntry(input:100)]]
        sample.tokenHistory.period = .week;render("week-missing-days")
        sample.tokenHistory.period = .all;render("single-day")
    }
}
