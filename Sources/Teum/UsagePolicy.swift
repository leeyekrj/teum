import SwiftUI

enum UsageMode:String,Codable,CaseIterable {
    case balanced,reset,today,deadline
    var title:String {switch self {case .balanced:"균등 배분";case .reset:"리셋 전 소진";case .today:"오늘 소진";case .deadline:"지정일까지 소진"}}
}
struct UsagePolicy:Codable,Equatable {
    var mode:UsageMode = .balanced
    var deadlineAt:Double?
    var expectedResetAt:Double?
    var spendReserve = false
    func deadline(now:Date,reset:Date,calendar:Calendar = .current)->Date? {
        switch mode {
        case .balanced:return nil
        case .reset:return reset
        case .today,.deadline:
            guard let deadlineAt,deadlineAt.isFinite,deadlineAt>now.timeIntervalSince1970 else{return nil}
            return min(Date(timeIntervalSince1970:deadlineAt),reset)
        }
    }
}

struct UsagePolicyEditor:View {
    @ObservedObject var store:QuotaStore
    let stream:Stream
    private var policy:UsagePolicy {store.prefs.usagePolicies[stream.id] ?? UsagePolicy()}
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack(spacing:9) {
                BrandMark(stream:stream,size:18);Text(stream.name).font(.system(size:12));Spacer()
                Picker("사용 방식",selection:Binding(get:{policy.mode},set:{mode in
                    var next = policy;next.mode = mode
                    if mode == .today {next.deadlineAt = Calendar.current.date(byAdding:.day,value:1,to:Calendar.current.startOfDay(for:.now))?.timeIntervalSince1970}
                    if mode == .deadline,next.deadlineAt.map({$0<=Date().timeIntervalSince1970}) ?? true {next.deadlineAt = Date().addingTimeInterval(86400).timeIntervalSince1970}
                    save(next)
                })) {ForEach(UsageMode.allCases,id:\.rawValue){Text($0.title).tag($0)}}.labelsHidden().frame(width:170)
            }
            if policy.mode == .deadline {
                DatePicker("소진 기한",selection:Binding(get:{Date(timeIntervalSince1970:policy.deadlineAt ?? Date().addingTimeInterval(86400).timeIntervalSince1970)},set:{var next = policy;next.deadlineAt = $0.timeIntervalSince1970;save(next)}),displayedComponents:[.date,.hourAndMinute]).font(.system(size:11))
            }
            if policy.mode == .today || policy.mode == .deadline,let stamp = policy.deadlineAt {
                Text((stamp>Date().timeIntervalSince1970 ? "적용 기한 " : "기한이 지나 균등 배분으로 계산 · ")+WindowLogic.exact(Date(timeIntervalSince1970:stamp))).font(.system(size:10)).foregroundStyle(Ink.secondary)
            }
            Toggle("보호량도 사용",isOn:Binding(get:{policy.spendReserve},set:{var next = policy;next.spendReserve = $0;save(next)})).font(.system(size:11))
            Toggle("예상 리셋 시각 직접 지정",isOn:Binding(get:{policy.expectedResetAt != nil},set:{enabled in
                var next = policy;next.expectedResetAt = enabled ? (store.currentPlan.accounts.first{$0.id == stream.id}?.reset ?? Date().addingTimeInterval(86400)).timeIntervalSince1970 : nil;save(next)
            })).font(.system(size:11))
            if policy.expectedResetAt != nil {
                DatePicker("예상 리셋",selection:Binding(get:{Date(timeIntervalSince1970:policy.expectedResetAt!)},set:{var next = policy;next.expectedResetAt = $0.timeIntervalSince1970;save(next)}),displayedComponents:[.date,.hourAndMinute]).font(.system(size:11))
                Text("계획에만 반영합니다. 실제 잔여량과 서비스 리셋 시각은 바꾸지 않습니다. 지정 시각이 지나면 서비스 값으로 돌아갑니다.").font(.system(size:10)).foregroundStyle(Ink.secondary).fixedSize(horizontal:false,vertical:true)
            }
        }.padding(.vertical,10)
    }
    private func save(_ next:UsagePolicy) {
        store.prefs.usagePolicies[stream.id] = next
        store.dailyGoals.recalculate(stream.id,prefs:store.prefs,readings:store.readings);store.save()
    }
}
