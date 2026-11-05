import SwiftUI

enum PlanText {
    static func points(_ value:Double)->String {value>0 && value<0.1 ? "<0.1" : value.formatted(.number.precision(.fractionLength(1)))}
    private static let clock:DateFormatter = {let f = DateFormatter();f.locale = Locale(identifier:"en_US_POSIX");f.timeZone = .current;f.dateFormat = "M/d HH:mm";return f}()
    static func reset(_ date:Date)->String {clock.string(from:date)}
    static func tokens(_ value:Double)->String {"≈"+TokenText.count(Int(value.rounded()))}
    static func recommendation(_ next:PlanAllowance,plan:QuotaPlan)->String {
        let points = next.todayRemaining.map{min($0,next.spendable)} ?? next.pressure(now:plan.now)
        var text = next.todayRemaining != nil ? "오늘 \(PlanText.points(points))%p 더 사용" : "리셋 전까지 하루 \(PlanText.points(points))%p"
        if let size = next.tokensPerPoint {text += " · "+tokens(size*points)+" 환산 토큰"}
        if plan.basis == "work" {text += " · 일하는 양 기준"}
        return text
    }
}

struct PlanRecommendation:View {
    let plan:QuotaPlan
    var otherTitle:String
    var openOther:()->Void
    var body:some View {
        HStack(spacing:10) {
            if let next = plan.next {
                BrandMark(stream:next.stream,size:22)
                VStack(alignment:.leading,spacing:4) {
                    Text("다음은 "+next.stream.name).font(.system(size:14,weight:.semibold)).lineLimit(1)
                    Text(PlanText.recommendation(next,plan:plan)).font(.system(size:10)).foregroundStyle(Ink.secondary).lineLimit(1)
                }
            } else {
                Image(systemName:"pause.circle").font(.system(size:19)).foregroundStyle(Ink.secondary)
                VStack(alignment:.leading,spacing:4) {
                    Text(plan.accounts.isEmpty ? "계획할 주간 한도가 없어요" : "다음 작업 전 한도를 확인하세요").font(.system(size:13,weight:.medium))
                    Text("최신 한도 · 오늘 목표 · 보호량을 함께 확인합니다.").font(.system(size:10)).foregroundStyle(Ink.secondary)
                }
            }
            Spacer(minLength:10)
            Button(action:openOther) {HStack(spacing:4){Text(otherTitle);Image(systemName:"arrow.right").font(.system(size:9))}.font(.system(size:10,weight:.medium)).frame(height:28).contentShape(Rectangle())}.buttonStyle(TeumTogglePressStyle()).foregroundStyle(Ink.secondary)
        }.frame(height:48).overlay(alignment:.bottom){Rectangle().fill(Ink.rule).frame(height:0.5)}
    }
}

struct PlanOptionsButton:View {
    @ObservedObject var store:QuotaStore
    var openSettings:()->Void
    @State private var presented = false
    var body:some View {
        Button {presented.toggle()} label:{Label("배분 설정",systemImage:"slider.horizontal.3").font(.system(size:10,weight:.medium)).padding(.horizontal,9).frame(height:28).background(Color.white.opacity(0.06),in:RoundedRectangle(cornerRadius:7)).contentShape(Rectangle())}.buttonStyle(TeumTogglePressStyle())
            .popover(isPresented:$presented,arrowEdge:.bottom){PlanOptionsPopover(store:store,openSettings:openSettings).environment(\.colorScheme,.dark).modifier(KeepPanelOpen(store:store))}
    }
}

struct PlanOptionsPopover:View {
    @ObservedObject var store:QuotaStore
    var openSettings:()->Void
    var expandCapacity = false
    @Environment(\.dismiss) private var dismiss
    @State private var showMath = false
    @State private var showOmissions = false
    @State private var showCapacity = false
    init(store:QuotaStore,openSettings:@escaping ()->Void,expandCapacity:Bool = false) {
        self.store = store;self.openSettings = openSettings;self.expandCapacity = expandCapacity
        _showCapacity = State(initialValue:expandCapacity)
    }
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("배분 설정").font(.system(size:16,weight:.semibold))
            group("기간") {
                HStack(spacing:6) {
                    choice("앞으로 7일",selected:store.prefs.planHorizon != "week"){store.prefs.planHorizon = "rolling"}
                    choice("이번 주",selected:store.prefs.planHorizon == "week"){store.prefs.planHorizon = "week"}
                }
            }
            group("대상") {
                HStack(spacing:6) {
                    choice("코딩 계정",selected:store.prefs.planScope != "all"){store.prefs.planScope = "coding"}
                    choice("전체 계정",selected:store.prefs.planScope == "all"){store.prefs.planScope = "all"}
                }
                LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],alignment:.leading,spacing:3) {
                    ForEach(store.prefs.streams.filter{$0.visible && $0.connected != false}) {stream in
                        Button {withAnimation(Motion.feedback){
                            if store.prefs.planExcluded.contains(stream.id) {store.prefs.planExcluded.removeAll{$0 == stream.id}}
                            else {store.prefs.planExcluded.append(stream.id)}
                            save()
                        }} label:{HStack(spacing:6){Image(systemName:store.prefs.planExcluded.contains(stream.id) ? "circle" : "checkmark.circle.fill").foregroundStyle(store.prefs.planExcluded.contains(stream.id) ? Ink.secondary : stream.tint);Text(stream.name).lineLimit(1);Spacer()}.font(.system(size:10)).frame(height:25).contentShape(Rectangle())}.buttonStyle(TeumTogglePressStyle()).accessibilityLabel(stream.name+" 계획에 포함").accessibilityValue(store.prefs.planExcluded.contains(stream.id) ? "꺼짐" : "켜짐")
                    }
                }
            }
            group("추천 기준") {
                HStack(spacing:6) {
                    choice("한도 비율 %p",selected:store.prefs.planBasis != "work"){store.prefs.planBasis = "percent"}
                    choice("일하는 양 추정",selected:store.prefs.planBasis == "work"){store.prefs.planBasis = "work"}
                }
                Text(store.prefs.planBasis == "work" ? "계정마다 1%p가 처리하는 환산 토큰을 이 Mac 로그로 추정해 비교합니다. 추정이 없는 계정은 %p 순서로 뒤에 둡니다." : "계정마다 자기 주간 한도의 %p로 비교합니다. 요금제 크기는 순서에 넣지 않습니다.")
                    .font(.system(size:9)).foregroundStyle(Ink.secondary).fixedSize(horizontal:false,vertical:true)
            }
            HStack {
                Text("주간 보호량").font(.system(size:11,weight:.medium))
                Spacer()
                GlyphButton(symbol:"minus",help:"주간 보호량 5% 낮추기",size:24){store.prefs.planReserve = max(0,store.prefs.planReserve-5);save()}.disabled(store.prefs.planReserve<=0)
                Text("\(Int(store.prefs.planReserve))%").font(.system(size:12,weight:.semibold)).monospacedDigit().frame(width:35)
                GlyphButton(symbol:"plus",help:"주간 보호량 5% 높이기",size:24){store.prefs.planReserve = min(50,store.prefs.planReserve+5);save()}.disabled(store.prefs.planReserve>=50)
            }
            Rectangle().fill(Ink.rule).frame(height:0.5)
            Button {dismiss();openSettings()} label:{Label("매일 목표·선호 AI 설정",systemImage:"target").font(.system(size:11)).frame(height:25).contentShape(Rectangle())}.buttonStyle(TeumTogglePressStyle())
            DisclosureGroup("계정별 1%p 크기",isExpanded:$showCapacity) {
                VStack(alignment:.leading,spacing:5) {
                    ForEach(store.prefs.streams.filter{$0.visible && $0.connected != false}) {stream in
                        HStack(spacing:6) {
                            Text(stream.name).lineLimit(1)
                            Spacer(minLength:6)
                            Text(store.capacity.estimates[stream.id]?.summary ?? "추정 전").foregroundStyle(store.capacity.estimates[stream.id]?.tokensPerPoint == nil ? Ink.secondary : Ink.text).lineLimit(1)
                        }.font(.system(size:10)).monospacedDigit()
                    }
                    Text("환산 토큰 = "+WorkTokens.formula+". 이 Mac의 로그만 읽으므로 다른 기기에서 쓴 양이 섞이면 작게 잡힙니다. 서로 다른 모델의 작업량을 정확히 같게 보지는 않습니다.").font(.system(size:9)).foregroundStyle(Ink.secondary).fixedSize(horizontal:false,vertical:true)
                    if let at = store.capacity.estimatedAt {Text("추정 "+at.formatted(.dateTime.month(.defaultDigits).day().hour().minute())+" · 6시간마다 갱신").font(.system(size:9)).foregroundStyle(Ink.secondary)}
                }.padding(.top,6)
            }.font(.system(size:10))
            DisclosureGroup("계산 기준",isExpanded:$showMath) {
                Text("주간 잔여에서 보호량을 뺀 뒤 리셋 전까지 배분합니다. 오늘은 남은 목표를 우선 반영하고, 나머지는 이후 날짜에 나눕니다. 리셋 뒤 100%는 예상입니다. 계정별 %p는 작업 시간·토큰으로 환산하지 않습니다.").font(.system(size:10)).foregroundStyle(Ink.secondary).fixedSize(horizontal:false,vertical:true).padding(.top,6)
            }.font(.system(size:10))
            let omitted = store.currentPlan.omitted
            if !omitted.isEmpty {
                DisclosureGroup("제외·미확인 \(omitted.count)개",isExpanded:$showOmissions) {
                    Text(omitted.map{$0.stream.name+" · "+$0.reason}.joined(separator:"\n")).font(.system(size:10)).foregroundStyle(Ink.secondary).padding(.top,5)
                }.font(.system(size:10))
            }
        }.padding(20).frame(width:330).background(Ink.ground).foregroundStyle(Ink.text)
    }
    private func choice(_ text:String,selected:Bool,action:@escaping()->Void)->some View {
        Button {withAnimation(Motion.feedback){action();save()}} label:{Text(text).font(.system(size:10,weight:selected ? .semibold : .regular)).frame(maxWidth:.infinity).frame(height:28).background(Color.white.opacity(selected ? 0.11 : 0.03),in:RoundedRectangle(cornerRadius:6)).contentShape(Rectangle())}.buttonStyle(TeumTogglePressStyle()).accessibilityAddTraits(selected ? [.isSelected] : [])
    }
    private func group<Content:View>(_ title:String,@ViewBuilder content:()->Content)->some View {
        VStack(alignment:.leading,spacing:8){Text(title).font(.system(size:10,weight:.medium)).foregroundStyle(Ink.secondary);content()}
    }
    private func save() {store.dailyGoals.observe(prefs:store.prefs,readings:store.readings);store.save()}
}

struct KeepPanelOpen:ViewModifier {
    var store:QuotaStore
    func body(content:Content)->some View {
        content.onAppear{store.panelInteractions += 1}.onDisappear{store.panelInteractions = max(0,store.panelInteractions-1)}
    }
}

struct GoalTargetEditor:View {
    @ObservedObject var store:QuotaStore
    @ObservedObject var goals:DailyGoalsStore
    let account:PlanAllowance
    var openSettings:()->Void
    @Environment(\.dismiss) private var dismiss
    private var value:Double {goals.today?.targets[account.id] ?? 0}
    var body:some View {
        VStack(alignment:.leading,spacing:15) {
            HStack(spacing:8){BrandMark(stream:account.stream,size:20);Text(account.stream.name+" · 오늘 목표").font(.system(size:13,weight:.semibold))}
            HStack(spacing:10) {
                GlyphButton(symbol:"minus",help:"오늘 목표 1%p 줄이기"){set(value-1)}.disabled(value<=0)
                TextField("오늘 목표",value:Binding(get:{value},set:set),format:.number.precision(.fractionLength(1))).font(.system(size:24,weight:.semibold)).monospacedDigit().textFieldStyle(.plain).multilineTextAlignment(.center).frame(width:95)
                Text("%p").font(.system(size:12)).foregroundStyle(Ink.secondary)
                GlyphButton(symbol:"plus",help:"오늘 목표 1%p 늘리기"){set(value+1)}.disabled(value>=1000)
            }.padding(10).background(Color.white.opacity(0.05),in:RoundedRectangle(cornerRadius:8))
            Text("주간 한도에서 오늘 사용할 최대량입니다. 사용 기록을 지우지 않고 목표선만 바꿉니다.").font(.system(size:10)).foregroundStyle(Ink.secondary).fixedSize(horizontal:false,vertical:true)
            HStack {
                Button("계산값 사용"){goals.recalculate(account.id,prefs:store.prefs,readings:store.readings)}.buttonStyle(TeumActionStyle())
                Spacer()
                Button("매일 목표 설정"){dismiss();openSettings()}.font(.system(size:10)).buttonStyle(TeumTogglePressStyle())
            }
            Button("오늘 남은 양 모두 사용") {
                var policy = store.prefs.usagePolicies[account.id] ?? UsagePolicy();policy.mode = .today;policy.spendReserve = true
                policy.deadlineAt = Calendar.current.date(byAdding:.day,value:1,to:Calendar.current.startOfDay(for:.now))?.timeIntervalSince1970
                store.prefs.usagePolicies[account.id] = policy;store.prefs.dailyGoalTargets.removeValue(forKey:account.id)
                goals.recalculate(account.id,prefs:store.prefs,readings:store.readings);store.save()
            }.buttonStyle(TeumActionStyle())
        }.padding(18).frame(width:280).background(Ink.ground).foregroundStyle(Ink.text)
    }
    private func set(_ next:Double) {withAnimation(Motion.feedback){goals.target(account.id,value:max(0,min(1000,next)))}}
}
