import SwiftUI

struct DailyGoalProgress:View {
    @ObservedObject var store:QuotaStore
    @ObservedObject var goals:DailyGoalsStore
    var openSettings:()->Void = {}
    @State private var editingID:String?
    private var nameWidth:CGFloat {store.prefs.panelWidth<580 ? 124 : 140}
    private var weekWidth:CGFloat {store.prefs.panelWidth<580 ? 86 : 100}
    var body:some View {
        let plan = store.currentPlan
        let accounts = plan.accounts.sorted{a,b in (store.prefs.streams.firstIndex(where:{$0.id == a.id}) ?? 0)<(store.prefs.streams.firstIndex(where:{$0.id == b.id}) ?? 0)}
        ScrollView {
            VStack(alignment:.leading,spacing:12) {
                HStack {
                    Text(Date().formatted(.dateTime.month(.defaultDigits).day().weekday())).font(.system(size:11,weight:.medium))
                    Spacer()
                    Text("목표 수치를 눌러 조정").font(.system(size:9)).foregroundStyle(Ink.secondary)
                    PlanOptionsButton(store:store,openSettings:openSettings)
                }.frame(height:28)
                PlanRecommendation(plan:plan,otherTitle:"배분 계획"){store.navigation.go(to:3)}
                if let day = goals.today,!accounts.isEmpty {
                    tableHeader
                    VStack(spacing:0) {
                        ForEach(accounts) {account in
                            if let target = day.targets[account.id] {row(account,target:target,used:day.used[account.id] ?? 0,now:plan.now)}
                        }
                    }
                    HStack(spacing:7) {
                        Image(systemName:"info.circle")
                        Text("관측 "+day.startedAt.formatted(.dateTime.hour().minute())+" 이후 · 리셋과 사용 방식 반영 · %p").lineLimit(1)
                    }.font(.system(size:9)).foregroundStyle(Ink.secondary)
                        .help("오늘 사용은 관측한 주간 잔여 감소분의 합입니다. 첫 조회 전이나 조회 사이 리셋에 가려진 소비는 누락될 수 있습니다. 주간 막대의 가는 선은 고른 사용 기준, 오늘 막대의 선은 직접 정한 목표입니다.")
                } else {
                    Text("최신 주간 한도가 있는 계정을 연결하거나 배분 설정에서 대상을 확인해 주세요.").font(.system(size:12)).foregroundStyle(Ink.secondary).fixedSize(horizontal:false,vertical:true).padding(.vertical,20)
                }
                if let error = goals.error {Text(error).font(.system(size:10)).foregroundStyle(Ink.amber)}
            }.padding(.horizontal,36).padding(.top,4).padding(.bottom,16)
        }.scrollIndicators(.hidden).onAppear{goals.observe(prefs:store.prefs,readings:store.readings)}
    }
    private var tableHeader:some View {
        HStack(spacing:12) {
            Text("계정").frame(width:nameWidth,alignment:.leading)
            Text("주간 잔여").frame(width:weekWidth,alignment:.leading)
            Text("오늘 사용 / 목표").frame(maxWidth:.infinity,alignment:.leading)
            Text("남은 몫").frame(width:60,alignment:.trailing)
        }.font(.system(size:10,weight:.medium)).foregroundStyle(Ink.secondary).frame(height:18)
    }
    private func row(_ account:PlanAllowance,target:Double,used:Double,now:Date)->some View {
        let over = used>target+0.001
        let available = min(max(0,target-used),account.spendable)
        let guide = store.prefs.showPaceGuide ? account.window.flatMap{PaceGuide.remaining($0,now:now)} : nil
        return HStack(spacing:12) {
            HStack(spacing:7) {
                BrandMark(stream:account.stream,size:18)
                VStack(alignment:.leading,spacing:4) {
                    Text(account.stream.name).font(.system(size:11,weight:.medium)).lineLimit(1).truncationMode(.middle)
                    Text(account.shortBlocked ? "단기 한도 대기" : account.spendable<=0 ? "주간 보호량 도달" : (account.expectedReset ? "예상 리셋 " : "리셋 ")+PlanText.reset(account.reset)).font(.system(size:9)).foregroundStyle(account.shortBlocked || account.spendable<=0 ? Ink.amber : Ink.secondary).lineLimit(1)
                }
            }.frame(width:nameWidth,alignment:.leading)
            VStack(alignment:.leading,spacing:MeterLayout.textGap) {
                Text("\(Int(account.remaining.rounded()))%").font(.system(size:12,weight:.semibold)).monospacedDigit().contentTransition(.numericText())
                QuotaMeter(value:account.remaining,tint:account.stream.tint,delay:0,settled:true,pace:guide)
            }.frame(width:weekWidth).help(guide.map{PaceGuide.text($0)} ?? "실제 주간 잔여량")
            Button {editingID = account.id} label:{
                VStack(alignment:.leading,spacing:MeterLayout.textGap) {
                    HStack(spacing:4) {
                        Text(PlanText.points(used)).fontWeight(.semibold).foregroundStyle(over ? Ink.amber : Ink.text).contentTransition(.numericText())
                        Text("/").foregroundStyle(Ink.secondary)
                        Text(PlanText.points(target)).foregroundStyle(Ink.secondary).contentTransition(.numericText())
                        Image(systemName:"pencil").font(.system(size:8)).foregroundStyle(Ink.secondary.opacity(0.7))
                    }.font(.system(size:12)).monospacedDigit()
                    GeometryReader {g in
                        ZStack(alignment:.leading) {
                            Capsule().fill(Color.white.opacity(0.10)).frame(height:MeterLayout.trackHeight)
                            // Over the target shows in the amber numbers; the bar keeps the account colour.
                            Capsule().fill(account.stream.tint).frame(width:g.size.width*min(1,used/max(100,target,used)),height:MeterLayout.trackHeight)
                            Rectangle().fill(Ink.text.opacity(0.8)).frame(width:1.5,height:MeterLayout.guideHeight).offset(x:min(g.size.width-1.5,g.size.width*target/max(100,target,used)))
                        }.frame(height:MeterLayout.guideHeight)
                    }.frame(height:MeterLayout.guideHeight)
                }.frame(maxWidth:.infinity,alignment:.leading).frame(height:38).contentShape(Rectangle())
            }.buttonStyle(TeumTogglePressStyle()).help("오늘 목표 조정 · 주간 한도 %p 기준")
                .accessibilityLabel(account.stream.name+" 오늘 목표 조정").accessibilityValue("사용 \(PlanText.points(used)), 목표 \(PlanText.points(target))%p")
                .popover(isPresented:Binding(get:{editingID == account.id},set:{if !$0 {editingID = nil}}),arrowEdge:.trailing){GoalTargetEditor(store:store,goals:goals,account:account,openSettings:openSettings).environment(\.colorScheme,.dark).modifier(KeepPanelOpen(store:store))}
            VStack(alignment:.trailing,spacing:4) {
                Text(over ? "+"+PlanText.points(used-target) : account.shortBlocked ? "대기" : PlanText.points(available)).font(.system(size:12,weight:.semibold)).monospacedDigit().contentTransition(.numericText())
                Text(over ? "초과" : account.shortBlocked ? "단기 한도" : account.tokensPerPoint.map{"%p "+PlanText.tokens($0*available)} ?? "%p").font(.system(size:9)).monospacedDigit().lineLimit(1)
            }.foregroundStyle(over || account.shortBlocked ? Ink.amber : Ink.secondary).frame(width:60,alignment:.trailing)
                .help(account.tokensPerPoint.map{"남은 몫 \(PlanText.points(available))%p "+PlanText.tokens($0*available)+" 환산 토큰 · 1%p "+PlanText.tokens($0)} ?? "남은 몫 · 이 계정은 1%p 크기를 추정하지 못했어요")
        }.frame(height:44).overlay(alignment:.bottom){Rectangle().fill(Ink.rule).frame(height:0.5)}
            .animation(Motion.feedback,value:used).animation(Motion.feedback,value:target)
    }
}

struct DailyGoalSettings:View {
    @ObservedObject var store:QuotaStore
    @ObservedObject var goals:DailyGoalsStore
    init(store:QuotaStore) {self.store = store;self.goals = store.dailyGoals}
    private var streams:[Stream] {store.prefs.streams.filter{$0.visible && $0.connected != false}}
    private var preferred:[Stream] {store.prefs.planPriority.compactMap{id in streams.first{$0.id == id}}}
    var body:some View {
        VStack(alignment:.leading,spacing:22) {
            VStack(alignment:.leading,spacing:12) {
                HStack {
                    Text("선호 AI 순서").font(.system(size:14,weight:.semibold))
                    Spacer()
                    if !preferred.isEmpty {Button("자동으로"){withAnimation(Motion.feedback){store.prefs.planPriority = [];store.save()}}.buttonStyle(TeumActionStyle())}
                }
                Text(preferred.isEmpty ? "자동 · 리셋까지 활용할 잔여량을 기준으로 추천합니다." : "사용 가능한 계정 안에서 이 순서를 우선합니다. 단기 소진·주간 보호량·오늘 목표에 도달한 계정은 뒤로 보냅니다.").font(.system(size:11)).foregroundStyle(Ink.secondary).fixedSize(horizontal:false,vertical:true)
                ForEach(Array(preferred.enumerated()),id:\.element.id) {i,s in
                    HStack(spacing:9) {
                        Text(String(i+1)).font(.system(size:11)).foregroundStyle(Ink.secondary).frame(width:16)
                        BrandMark(stream:s,size:18);Text(s.name).font(.system(size:12));Spacer()
                        GlyphButton(symbol:"chevron.up",help:s.name+" 우선순위 올리기"){move(s.id,by:-1)}.disabled(i == 0)
                        GlyphButton(symbol:"chevron.down",help:s.name+" 우선순위 내리기"){move(s.id,by:1)}.disabled(i == preferred.count-1)
                        GlyphButton(symbol:"xmark",help:s.name+" 선호 해제"){store.prefs.planPriority.removeAll{$0 == s.id};store.save()}
                    }.frame(height:34)
                }
                LazyVGrid(columns:[GridItem(.adaptive(minimum:120),alignment:.leading)],alignment:.leading,spacing:7) {
                    ForEach(streams.filter{!store.prefs.planPriority.contains($0.id)}) {s in
                        Button {withAnimation(Motion.feedback){store.prefs.planPriority.append(s.id);store.save()}} label:{HStack(spacing:6){Image(systemName:"plus").font(.system(size:9));Text(s.name).font(.system(size:11)).lineLimit(1);Spacer()}.padding(.horizontal,9).frame(height:30).background(Color.white.opacity(0.04),in:RoundedRectangle(cornerRadius:6)).contentShape(Rectangle())}.buttonStyle(TeumTogglePressStyle())
                    }
                }
            }
            Rectangle().fill(Ink.rule).frame(height:1)
            VStack(alignment:.leading,spacing:12) {
                Text("계정별 사용 방식과 리셋").font(.system(size:14,weight:.semibold))
                Text("리셋이 가까운 계정을 먼저 쓰거나 남은 양을 오늘·지정일까지 배분합니다. 오늘 소진은 오늘 자정까지만 적용됩니다. 직접 정한 오늘 목표·매일 목표가 있으면 그 값을 우선합니다.").font(.system(size:11)).foregroundStyle(Ink.secondary).fixedSize(horizontal:false,vertical:true)
                ForEach(streams) {s in UsagePolicyEditor(store:store,stream:s)}
            }
            Rectangle().fill(Ink.rule).frame(height:1)
            VStack(alignment:.leading,spacing:12) {
                Text("매일 반복할 최대 사용 목표").font(.system(size:14,weight:.semibold))
                Text("주간 한도의 %p 기준입니다. 균등 배분은 첫 조회 목표를 유지하고, 소진 방식은 잔여량·기한에 맞춰 갱신합니다. 리셋되면 관측한 오늘 사용에 새 몫을 더합니다.").font(.system(size:11)).foregroundStyle(Ink.secondary).fixedSize(horizontal:false,vertical:true)
                ForEach(streams) {s in
                    HStack(spacing:9) {
                        BrandMark(stream:s,size:18);Text(s.name).font(.system(size:12));Spacer()
                        if let value = store.prefs.dailyGoalTargets[s.id] {
                            GlyphButton(symbol:"minus",help:s.name+" 매일 목표 줄이기"){set(s.id,max(0,value-1))}.disabled(value<=0)
                            Text(String(format:"%.0f%%p",value)).font(.system(size:12,weight:.medium)).monospacedDigit().frame(width:46)
                            GlyphButton(symbol:"plus",help:s.name+" 매일 목표 늘리기"){set(s.id,min(100,value+1))}.disabled(value>=100)
                            Button("자동"){store.prefs.dailyGoalTargets.removeValue(forKey:s.id);store.save();goals.automatic(prefs:store.prefs,readings:store.readings)}.buttonStyle(TeumActionStyle())
                        } else {
                            Text("자동").font(.system(size:11)).foregroundStyle(Ink.secondary)
                            Button("직접 설정"){set(s.id,goals.today?.targets[s.id] ?? 10)}.buttonStyle(TeumActionStyle())
                        }
                    }.frame(height:35)
                }
            }
            Text("목표는 권고입니다. 세션 중단을 원하면 합의한 기준을 teum-cli 일회성 세션 알림으로 등록하세요. 주간 한도가 없는 계정은 계획 대상에서 제외됩니다.").font(.system(size:10)).foregroundStyle(Ink.secondary).fixedSize(horizontal:false,vertical:true)
        }.onAppear{goals.observe(prefs:store.prefs,readings:store.readings)}
    }
    private func set(_ id:String,_ value:Double) {withAnimation(Motion.feedback){store.prefs.dailyGoalTargets[id] = value;store.save();goals.target(id,value:value)}}
    private func move(_ id:String,by step:Int) {
        guard let i = store.prefs.planPriority.firstIndex(of:id) else{return}
        let j = i+step;guard store.prefs.planPriority.indices.contains(j) else{return}
        withAnimation(Motion.feedback){store.prefs.planPriority.swapAt(i,j);store.save()}
    }
}
