import SwiftUI
import QuotaModel

struct IslandNotice:Identifiable {
    enum Kind {case reset,recovery,low,empty,pace,goalNear,goalReached}
    var id = UUID()
    let stream:Stream
    let windowID:String
    let kind:Kind
    let before:Double
    let remaining:Double
    let detail:String
    var title:String {switch kind {case .reset,.recovery:"한도가 리셋됐어요";case .low:"잔여량이 줄었어요";case .empty:"사용량을 모두 썼어요";case .pace:"고른 사용 기준보다 빨라요";case .goalNear:"오늘 목표가 얼마 남지 않았어요";case .goalReached:"오늘 사용 목표에 도달했어요"}}
    var isGoal:Bool {kind == .goalNear || kind == .goalReached}
    var valueCaption:String {isGoal ? "% 목표 남음" : "% 남음"}
}

/// Announcements come only from newly fetched, valid provider data.
@MainActor struct NoticeEngine {
    var previous:[String:UsageSnapshot] = [:]
    private var observed = Set<String>()
    private var pendingReset:[String:(date:Date,before:Double)] = [:]
    private var paceDelivered:[String:Date] = [:]
    private var goalPrevious:[String:(day:String,target:Double,used:Double)] = [:]
    private var goalDelivered = Set<String>()
    init(previous:[String:UsageSnapshot] = [:]) {self.previous = previous}
    mutating func events(prefs:Preferences,readings:[String:Reading],goals:DailyGoalDay? = nil)->[IslandNotice] {
        var result:[IslandNotice] = []
        for s in prefs.streams {
            guard let reading = readings[s.id],let now = reading.snapshot,!reading.stale(minutes:prefs.refreshMinutes),now.fetchedAt <= Date().addingTimeInterval(30),previous[s.id]?.fetchedAt != now.fetchedAt else {continue}
            let old = previous[s.id]
            defer {previous[s.id] = now;observed.insert(s.id)}
            guard s.visible,s.connected != false else{continue}
            var found:[IslandNotice] = []
            if let goals,let target = goals.targets[s.id],target > 0 {
                let used = goals.used[s.id] ?? 0
                let day = DailyGoalsStore.key(now.fetchedAt)
                let prior = goalPrevious[s.id]
                goalPrevious[s.id] = (day,target,used)
                if prefs.islandNotices,s.warns,s.notifyLow != false,let prior,prior.day == day,abs(prior.target-target)<0.001,used>prior.used {
                    let left = max(0,100*(target-used)/target),before = max(0,100*(target-prior.used)/target)
                    let key = s.id+"|"+day
                    let reached = used>=target && prior.used<target
                    let near = left<=max(1,min(90,prefs.goalRemainingThreshold)) && before>max(1,min(90,prefs.goalRemainingThreshold))
                    let kind:IslandNotice.Kind? = reached && prefs.goalReachedNotices && !goalDelivered.contains(key+"reached") ? .goalReached : !reached && near && prefs.goalNearNotices && !goalDelivered.contains(key+"near") ? .goalNear : nil
                    if let kind {
                        goalDelivered.insert(key+(kind == .goalReached ? "reached" : "near"))
                        found.append(IslandNotice(stream:s,windowID:"goal:"+day,kind:kind,before:before,remaining:left,detail:"오늘 \(PlanText.points(used)) / \(PlanText.points(target))%p 사용"))
                    }
                }
            }
            guard prefs.islandNotices else{continue}
            for w in WindowLogic.primary(now.windows) {
                guard !s.ignoredWindows.contains(w.id),!WindowLogic.expired(w,snapshot:now),let remaining = WindowLogic.remaining(w) else{continue}
                let before = old?.windows.first{$0.id == w.id}
                let leftBefore = before.flatMap(WindowLogic.remaining)
                let resetWasDue = before?.resetsAt.map{$0 <= now.fetchedAt && $0 > (old?.fetchedAt ?? .distantFuture)} ?? false
                let recent = old.map{now.fetchedAt.timeIntervalSince($0.fetchedAt) < 86400} ?? false
                let resetKey = s.id+"|"+w.id
                if prefs.paceNotices,prefs.usagePolicies[s.id]?.deadline(now:now.fetchedAt,reset:w.resetsAt ?? now.fetchedAt) == nil,s.warns,s.notifyLow != false,recent,let before,let leftBefore,let reset = w.resetsAt,before.resetsAt == reset,
                   let guide = PaceGuide.remaining(w,now:now.fetchedAt),let oldGuide = PaceGuide.remaining(before,now:old!.fetchedAt),
                   remaining<guide,leftBefore>=oldGuide,paceDelivered[resetKey] != reset {
                    paceDelivered[resetKey] = reset
                    found.append(IslandNotice(stream:s,windowID:w.id,kind:.pace,before:leftBefore,remaining:remaining,detail:WindowLogic.label(w)+" · 고른 사용 기준 \(Int(guide.rounded()))%"))
                }
                if prefs.resetNotices,s.notifyReset != false,recent,resetWasDue,let date = before?.resetsAt,let leftBefore,pendingReset[resetKey] == nil {
                    pendingReset[resetKey] = (date,leftBefore)
                }
                let pending = pendingReset[resetKey]
                let advanced = pending.flatMap{old in w.resetsAt.map{$0>old.date.addingTimeInterval(1)}} ?? false
                let recovered = pending.map{remaining>$0.before+5} ?? false
                let confirmed = pending != nil && (advanced || recovered)
                if let pending,now.fetchedAt.timeIntervalSince(pending.date)>300 {pendingReset[resetKey] = nil}
                if prefs.resetNotices,s.notifyReset != false,confirmed,let pending,pendingReset[resetKey] != nil {
                    pendingReset[resetKey] = nil
                    found.append(IslandNotice(stream:s,windowID:w.id,kind:.reset,before:pending.before,remaining:remaining,detail:WindowLogic.label(w)))
                } else if prefs.resetNotices,s.notifyReset != false,recent,let leftBefore,remaining>leftBefore+5 {
                    // Provider grants/resets can happen before the advertised date.
                    // Report the observed recovery without inventing its cause.
                    found.append(IslandNotice(stream:s,windowID:w.id,kind:.recovery,before:leftBefore,remaining:remaining,detail:WindowLogic.label(w)))
                } else if prefs.lowNotices,s.warns,s.notifyLow != false,remaining <= prefs.threshold,
                    (!observed.contains(s.id) || (leftBefore ?? 101)>prefs.threshold || (remaining == 0 && (leftBefore ?? 0)>0)) {
                    found.append(IslandNotice(stream:s,windowID:w.id,kind:remaining == 0 ? .empty : .low,before:leftBefore ?? remaining,remaining:remaining,detail:WindowLogic.label(w)))
                }
            }
            // One concise notice per account per refresh. Exhaustion wins over a reset.
            if let event = found.first(where:{$0.kind == .empty}) ?? found.first(where:{$0.kind == .goalReached}) ?? found.first(where:{$0.kind == .low}) ?? found.first {result.append(event)}
        }
        return result
    }
}

struct IslandNoticeView:View {
    let notice:IslandNotice
    var settled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrived:Bool
    @State private var textArrived:Bool
    @State private var valueArrived:Bool
    @State private var ring:Double
    @State private var number:Double
    init(notice:IslandNotice,settled:Bool = false) {
        self.notice = notice;self.settled = settled
        _arrived = State(initialValue:settled);_textArrived = State(initialValue:settled);_valueArrived = State(initialValue:settled)
        _ring = State(initialValue:max(0,min(1,notice.before/100)));_number = State(initialValue:notice.before)
    }
    private var color:Color {notice.kind == .reset || notice.kind == .recovery ? notice.stream.tint : notice.kind == .empty ? Ink.red : Ink.amber}
    var body:some View {
        HStack(spacing:14) {
            ZStack {
                Circle().stroke(color.opacity(0.14),lineWidth:3)
                Circle().trim(from:0,to:settled ? notice.remaining/100 : ring).stroke(color,style:StrokeStyle(lineWidth:3,lineCap:.round)).rotationEffect(.degrees(-90))
                BrandMark(stream:notice.stream,size:20)
            }.frame(width:40,height:40).opacity(arrived ? 1 : 0).scaleEffect(reduceMotion || arrived ? 1 : 0.94)
            VStack(alignment:.leading,spacing:5) {
                Text(notice.title).font(.system(size:14,weight:.semibold))
                Text("\(notice.stream.name) · \(notice.detail)").font(.system(size:11)).foregroundStyle(Ink.secondary).lineLimit(1)
            }.opacity(textArrived ? 1 : 0).offset(y:reduceMotion || textArrived ? 0 : 5)
            Spacer(minLength:8)
            HStack(alignment:.firstTextBaseline,spacing:4) {
                AnimatedQuotaNumber(value:settled ? notice.remaining : number).font(.system(size:26,weight:.semibold)).monospacedDigit()
                Text(notice.valueCaption).font(.system(size:11)).foregroundStyle(Ink.secondary)
            }.foregroundStyle(color).opacity(valueArrived ? 1 : 0).offset(y:reduceMotion || valueArrived ? 0 : 5)
        }.padding(.horizontal,32).frame(height:80).background(.black).foregroundStyle(Ink.text)
            .onAppear {
                if settled || reduceMotion {
                    arrived = true;textArrived = true;valueArrived = true;number = notice.remaining;ring = notice.remaining/100;return
                }
                withAnimation(.spring(response:0.45,dampingFraction:1).delay(0.04)){arrived = true}
                withAnimation(.easeOut(duration:0.24).delay(0.1)){textArrived = true}
                withAnimation(.easeOut(duration:0.22).delay(0.16)){valueArrived = true}
                withAnimation(.timingCurve(0.16,1,0.3,1,duration:0.9).delay(0.12)){ring = notice.remaining/100}
                withAnimation(.easeOut(duration:0.75).delay(0.18)){number = notice.remaining}
            }.accessibilityElement(children:.combine)
    }
}

private struct AnimatedQuotaNumber:View,Animatable {
    var value:Double
    var animatableData:Double {get{value} set{value = newValue}}
    var body:some View {Text(Int(value.rounded()),format:.number)}
}
