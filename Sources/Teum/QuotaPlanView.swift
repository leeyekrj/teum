import SwiftUI

/// One independent page: accounts form the rows, calendar days the columns.
struct QuotaPlanView:View {
    @ObservedObject var store:QuotaStore
    @ObservedObject var goals:DailyGoalsStore
    var openSettings:()->Void
    @State private var selectedDay = 0
    private var nameWidth:CGFloat {store.prefs.panelWidth<580 ? 124 : 140}
    init(store:QuotaStore,openSettings:@escaping()->Void = {}) {self.store = store;self.goals = store.dailyGoals;self.openSettings = openSettings}
    var body:some View {
        let plan = store.currentPlan
        let values = plan.days.map{Dictionary(uniqueKeysWithValues:plan.allocations(day:$0).map{($0.id,$0)})}
        ScrollView {
            VStack(alignment:.leading,spacing:12) {
                HStack(spacing:8) {
                    Text(store.prefs.planHorizon == "week" ? "이번 주" : "앞으로 7일").font(.system(size:11,weight:.medium))
                    Text(plan.now.formatted(.dateTime.month(.defaultDigits).day())+"–"+plan.end.formatted(.dateTime.month(.defaultDigits).day())).font(.system(size:9)).foregroundStyle(Ink.secondary)
                    Spacer(minLength:4)
                    PlanOptionsButton(store:store,openSettings:openSettings)
                }.frame(height:28)
                PlanRecommendation(plan:plan,otherTitle:"오늘 목표"){store.navigation.go(to:2)}
                if !plan.accounts.isEmpty {
                    dayHeader(plan)
                    VStack(spacing:0) {
                        ForEach(Array(plan.accounts.enumerated()),id:\.element.id) {index,account in
                            matrixRow(account,index:index,plan:plan,values:values)
                        }
                    }
                    HStack(spacing:7) {
                        Circle().fill(Ink.amber).frame(width:3,height:3)
                        Text("리셋").font(.system(size:9))
                        Text("· 회색은 리셋 이후 예상 · 단위 %p"+(plan.basis == "work" ? " · 순서는 일하는 양" : "")).font(.system(size:9))
                        Spacer(minLength:3)
                        Text("오늘 목표와 연동").font(.system(size:9))
                    }.foregroundStyle(Ink.secondary).help("오늘은 목표 페이지의 남은 몫을 우선 반영하고 나머지 주간 한도를 이후 날짜에 나눕니다. 리셋 뒤에는 100%를 가정합니다. 서로 다른 계정의 %p는 작업 시간이나 토큰 수로 합산하지 않습니다.")
                } else {
                    Text("배분 설정에서 계정 범위를 확인하거나 최신 사용량을 다시 읽어 주세요.").font(.system(size:12)).foregroundStyle(Ink.secondary).fixedSize(horizontal:false,vertical:true).padding(.vertical,20)
                    Button("사용량 새로고침"){Task{await store.refresh()}}.buttonStyle(TeumActionStyle())
                }
            }.padding(.horizontal,36).padding(.top,4).padding(.bottom,16)
        }.scrollIndicators(.hidden).onAppear{goals.observe(prefs:store.prefs,readings:store.readings)}
    }
    private func dayHeader(_ plan:QuotaPlan)->some View {
        HStack(spacing:12) {
            Text("추천순 · 계정").font(.system(size:10,weight:.medium)).foregroundStyle(Ink.secondary).frame(width:nameWidth,alignment:.leading)
            HStack(spacing:4) {
                ForEach(Array(plan.days.enumerated()),id:\.element.id) {index,day in
                    Button {withAnimation(Motion.feedback){selectedDay = index}} label:{
                        VStack(spacing:3) {
                            Text(index == 0 ? "오늘" : day.start.formatted(.dateTime.weekday(.abbreviated))).font(.system(size:9))
                            Text(day.start.formatted(.dateTime.day())).font(.system(size:11,weight:.semibold)).monospacedDigit()
                        }.frame(maxWidth:.infinity).frame(height:34).background(index == selectedDay ? Color.white.opacity(0.09) : .clear,in:RoundedRectangle(cornerRadius:5)).contentShape(Rectangle())
                    }.buttonStyle(TeumTogglePressStyle()).foregroundStyle(index == selectedDay ? Ink.text : Ink.secondary).accessibilityLabel(day.start.formatted(.dateTime.month().day())+" 배분 비교").accessibilityAddTraits(index == selectedDay ? [.isSelected] : [])
                }
            }.frame(maxWidth:.infinity)
        }
    }
    private func matrixRow(_ a:PlanAllowance,index:Int,plan:QuotaPlan,values:[[String:PlanAllocation]])->some View {
        HStack(spacing:12) {
            HStack(spacing:6) {
                Text(String(index+1)).font(.system(size:9)).monospacedDigit().foregroundStyle(Ink.secondary).frame(width:10)
                BrandMark(stream:a.stream,size:16)
                VStack(alignment:.leading,spacing:4) {
                    Text(a.stream.name).font(.system(size:11,weight:.medium)).lineLimit(1).truncationMode(.middle)
                    Text(a.shortBlocked ? "단기 한도 대기" : "\(Int(a.remaining.rounded()))% · "+(a.expectedReset ? "예상 " : "")+PlanText.reset(a.reset)).font(.system(size:9)).foregroundStyle(a.shortBlocked ? Ink.amber : Ink.secondary).lineLimit(1)
                }
            }.frame(width:nameWidth,alignment:.leading).help(accountHelp(a))
            HStack(spacing:4) {
                ForEach(Array(plan.days.enumerated()),id:\.element.id) {dayIndex,day in
                    cell(a,day:day,index:dayIndex,allocation:values[dayIndex][a.id])
                }
            }.frame(maxWidth:.infinity)
        }.frame(height:44).overlay(alignment:.bottom){Rectangle().fill(Ink.rule).frame(height:0.5)}
    }
    private func accountHelp(_ a:PlanAllowance)->String {
        let base = a.stream.name+" · 주간 잔여 \(Int(a.remaining.rounded()))% · 리셋 "+WindowLogic.exact(a.reset)
        guard let size = a.tokensPerPoint else {return base+"\n1%p 크기 추정 없음"}
        return base+"\n1%p "+PlanText.tokens(size)+" 환산 토큰 · 남은 몫 "+PlanText.tokens(size*a.spendable)
    }
    private func cell(_ a:PlanAllowance,day:PlanDay,index:Int,allocation:PlanAllocation?)->some View {
        let points = allocation?.points ?? 0
        let projected = allocation?.projected == true
        let resets = a.reset>=day.start && a.reset<day.end
        return Text(points>0 ? PlanText.points(points) : "0").font(.system(size:11,weight:projected ? .regular : .medium)).monospacedDigit()
            .foregroundStyle(projected || points == 0 ? Ink.secondary : a.stream.tint)
            .frame(maxWidth:.infinity).frame(height:31)
            .background(index == selectedDay ? Color.white.opacity(0.045) : .clear,in:RoundedRectangle(cornerRadius:4))
            .overlay(alignment:.topTrailing){if resets {Circle().fill(Ink.amber).frame(width:3,height:3).padding(3)}}
            .help(a.stream.name+" · "+day.start.formatted(.dateTime.month().day())+" · \(PlanText.points(points))%p"+(projected ? " · 리셋 이후 예상" : "")+(resets ? " · 이날 주간 리셋" : ""))
            .accessibilityLabel(a.stream.name+" "+day.start.formatted(.dateTime.month().day())+" 목표 "+PlanText.points(points)+"%p"+(projected ? " 예상" : ""))
    }
}
