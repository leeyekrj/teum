import SwiftUI
import QuotaModel

/// DateFormatter is costly to create, and the panel formats many dates on
/// every redraw. Formatting with an unchanged formatter is thread-safe.
enum DateFormats {
    nonisolated(unsafe) private static var cache:[String:DateFormatter] = [:]
    private static let lock = NSLock()
    static func formatter(_ format:String,calendar:Calendar = .current)->DateFormatter {
        let key = "\(format)|\(calendar.identifier)|\(calendar.timeZone.identifier)"
        lock.lock();defer {lock.unlock()}
        if let cached = cache[key] {return cached}
        let f = DateFormatter();f.locale = Locale(identifier:"ko_KR");f.calendar = calendar;f.timeZone = calendar.timeZone;f.dateFormat = format
        cache[key] = f;return f
    }
}

/// When a window empties if use continues at its average rate so far.
/// Uses the vendored pace model: it needs the window length, and stays
/// silent until 5% of the window and 15 minutes have passed.
enum RunOut {
    static func date(_ w:UsageWindow,now:Date = .now)->Date? {
        w.pace(now:now)?.runOutSeconds.map{now.addingTimeInterval($0)}
    }
    /// Row text, only when the window would empty before it resets.
    static func text(_ w:UsageWindow,compact:Bool = false,now:Date = .now)->String? {
        guard let date = date(w,now:now) else{return nil}
        return clock(date,now:now,compact:compact)+" 소진 예정"
    }
    /// Longest first, for the space left beside the reset time.
    static func variants(_ date:Date,now:Date = .now,calendar:Calendar = .current)->[String] {
        let time = DateFormats.formatter("HH:mm",calendar:calendar).string(from:date)
        // A bare time reads as its next occurrence, so it is only used within 24 hours.
        let soon = date.timeIntervalSince(now)<86400
        if calendar.isDate(date,inSameDayAs:now) {return [time+" 소진 예정","소진 예정"]}
        if let tomorrow = calendar.date(byAdding:.day,value:1,to:now),calendar.isDate(date,inSameDayAs:tomorrow) {
            return soon ? ["내일 "+time+" 소진 예정",time+" 소진 예정","내일 소진 예정","소진 예정"] : ["내일 "+time+" 소진 예정","내일 소진 예정","소진 예정"]
        }
        let day = DateFormats.formatter("M/d",calendar:calendar).string(from:date)
        return [day+" "+time+" 소진 예정",day+" 소진 예정","소진 예정"]
    }
    /// After an hourglass: the time within 24 hours, otherwise the date.
    static func short(_ date:Date,now:Date = .now,calendar:Calendar = .current)->String {
        if date.timeIntervalSince(now)<86400 {return DateFormats.formatter("HH:mm",calendar:calendar).string(from:date)}
        return DateFormats.formatter("M/d",calendar:calendar).string(from:date)
    }
    static func help(_ w:UsageWindow,now:Date = .now)->String {
        guard let date = date(w,now:now),let reset = w.resetsAt else{return ""}
        return "\n지금 속도면 \(clock(date,now:now)) 소진 예정 · 리셋 \(span(reset.timeIntervalSince(date))) 전"
    }
    static func detail(_ w:UsageWindow,now:Date = .now)->(text:String,warning:Bool)? {
        guard let pace = w.pace(now:now),pace.isSettled,pace.actualPercent>0,pace.actualPercent<99.5 else{return nil}
        if let date = date(w,now:now),let reset = w.resetsAt {
            return ("지금 속도면 \(clock(date,now:now)) 소진 예정 · 리셋 \(span(reset.timeIntervalSince(date))) 전",true)
        }
        let left = max(0,100-pace.projectedPercent)
        return ("지금 속도면 리셋 때 약 \(Int(left.rounded()))% 남아요",false)
    }
    static func clock(_ date:Date,now:Date = .now,compact:Bool = false,calendar:Calendar = .current)->String {
        let time = DateFormats.formatter("HH:mm",calendar:calendar).string(from:date)
        if calendar.isDate(date,inSameDayAs:now) {return compact ? time : "오늘 "+time}
        if let tomorrow = calendar.date(byAdding:.day,value:1,to:now),calendar.isDate(date,inSameDayAs:tomorrow) {return "내일 "+time}
        return DateFormats.formatter(compact ? "M/d HH:mm" : "M월 d일 HH:mm",calendar:calendar).string(from:date)
    }
    static func span(_ seconds:Double)->String {
        let minutes = max(1,Int((seconds/60).rounded()))
        if minutes<60 {return "\(minutes)분"}
        let hours = minutes/60
        if hours<24 {return minutes%60 == 0 ? "\(hours)시간" : "\(hours)시간 \(minutes%60)분"}
        let days = hours/24
        return hours%24 == 0 ? "\(days)일" : "\(days)일 \(hours%24)시간"
    }
}

/// The run-out time beside a reset time, shortened only as far as the space needs.
struct RunOutLabel:View {
    let date:Date
    var color:Color
    var size:CGFloat = 9
    var body:some View {
        ViewThatFits(in:.horizontal) {
            ForEach(RunOut.variants(date),id:\.self) {Text($0).fixedSize()}
            // Without the word, the hourglass says what the time means.
            HStack(spacing:2) {Image(systemName:"hourglass").font(.system(size:size-1));Text(RunOut.short(date)).fixedSize()}
            Image(systemName:"hourglass")
        }.font(.system(size:size)).monospacedDigit().foregroundStyle(color).lineLimit(1)
            .help("지금 속도면 "+RunOut.clock(date)+" 소진 예정")
    }
}

/// Codex grants window resets that expire unused. Teum only shows them.
struct ResetCreditsRow:View {
    let credits:ResetCredits
    var now:Date = .now
    var body:some View {
        let upcoming = credits.upcomingExpirations(now:now)
        let soon = upcoming.first.map{$0.timeIntervalSince(now)<86400} ?? false
        VStack(alignment:.leading,spacing:8) {
            HStack {
                Text("한도 재설정권").font(.system(size:12,weight:.medium))
                Spacer()
                Text("\(credits.available)개").font(.system(size:13,weight:.semibold)).monospacedDigit()
            }
            if let first = upcoming.first {
                Text("가장 빠른 만료 "+WindowLogic.exact(first)+(upcoming.count>1 ? " · 다음 "+RunOut.clock(upcoming[1],now:now) : ""))
                    .font(.system(size:11)).monospacedDigit().foregroundStyle(soon ? Ink.amber : Ink.secondary)
            } else if credits.available>0 {
                Text("만료 시각을 받지 못했어요").font(.system(size:11)).foregroundStyle(Ink.secondary)
            }
            if let title = credits.credits.first?.title,!title.isEmpty {Text(title).font(.system(size:11)).foregroundStyle(Ink.secondary)}
            Rectangle().fill(Ink.rule).frame(height:1)
        }.help("보유 \(credits.available)개"+((credits.totalEarned ?? 0)>0 ? " · 지금까지 받은 \(credits.totalEarned!)개" : "")+" · Teum은 재설정권을 쓰지 않고 표시만 합니다.")
    }
}
