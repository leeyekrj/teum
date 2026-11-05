import SwiftUI

struct SessionWatchRule:Decodable,Identifiable {
    var id:String
    var host:String
    var session:String
    var stream:String
    var window:String
    var below:Double
    var message:String
    var expiresAt:Double
    var state:String
    var active:Bool {state == "armed" && expiresAt>Date().timeIntervalSince1970}
    var windowName:String {window == "auto" ? "가장 낮은 한도" : window == "weekly" ? "주간" : window == "short" ? "단기" : window}
    static var samples:[SessionWatchRule] {[
        .init(id:"preview-a",host:"codex",session:"demo-codex-session",stream:"codex",window:"weekly",below:10,message:"진행 상태를 남기고 새 작업을 멈추기",expiresAt:Date().addingTimeInterval(7200).timeIntervalSince1970,state:"armed"),
        .init(id:"preview-b",host:"agy",session:"demo-agy-session",stream:"agy-general",window:"auto",below:15,message:"가벼운 모델로 바꿀 수 있는지 확인하기",expiresAt:Date().addingTimeInterval(3600).timeIntervalSince1970,state:"armed")
    ]}
}

struct SessionWatchSettings:View {
    let directory:URL
    let streams:[Stream]
    var previewRules:[SessionWatchRule]?
    @State private var rules:[SessionWatchRule] = []
    @State private var error:String?
    @State private var cancelling:String?
    @State private var showFinished = false
    init(directory:URL,streams:[Stream],previewRules:[SessionWatchRule]? = nil) {
        self.directory = directory;self.streams = streams;self.previewRules = previewRules;_rules = State(initialValue:previewRules ?? [])
    }
    private var active:[SessionWatchRule] {rules.filter(\.active)}
    private var finished:[SessionWatchRule] {rules.filter{!$0.active}}
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack {
                Text("활성 \(active.count)개").font(.system(size:13,weight:.semibold))
                Spacer()
                Button("다시 확인"){reload()}.buttonStyle(TeumActionStyle())
            }
            Text("각 AI 세션에서 합의한 일회성 조건입니다. 조건에 도달하면 해당 세션의 다음 훅·확인 시점에 한 번 전달하고 끝납니다.").font(.system(size:11)).foregroundStyle(Ink.secondary).fixedSize(horizontal:false,vertical:true)
            if active.isEmpty {
                VStack(alignment:.leading,spacing:9) {
                    Image(systemName:"bell.badge").font(.system(size:23)).foregroundStyle(Ink.secondary)
                    Text("등록된 세션 알림이 없어요").font(.system(size:15,weight:.semibold))
                    Text("작업 중인 AI에게 ‘이번 세션은 주간 잔여 10%가 되면 인계하고 멈추도록 teum-cli에 등록해 줘’처럼 요청하세요.").font(.system(size:12)).foregroundStyle(Ink.secondary).fixedSize(horizontal:false,vertical:true)
                }.padding(.vertical,25)
            }
            ForEach(active) {rule in ruleRow(rule)}
            if !finished.isEmpty {
                Button {withAnimation(Motion.feedback){showFinished.toggle()}} label: {
                    HStack {Text("종료된 알림 \(finished.count)개");Spacer();Image(systemName:showFinished ? "chevron.up" : "chevron.down")}.font(.system(size:11)).foregroundStyle(Ink.secondary).frame(height:28).contentShape(Rectangle())
                }.buttonStyle(TeumTogglePressStyle())
                if showFinished {ForEach(finished) {rule in ruleRow(rule)}}
            }
            if let error {Text(error).font(.system(size:11)).foregroundStyle(Ink.amber)}
            Text("기본 12시간 뒤 만료됩니다. 알림은 세션의 실행 중인 추론을 강제로 끊지 않으며, 멈춤·모델 변경은 세션이 합의한 대응에 따릅니다. 전역 사용량 경고와 별도로 관리됩니다.").font(.system(size:10)).foregroundStyle(Ink.secondary).fixedSize(horizontal:false,vertical:true)
        }.task {
            repeat {
                reload()
                do {try await Task.sleep(for:.seconds(2))} catch {return}
            } while !Task.isCancelled
        }
    }
    private func ruleRow(_ rule:SessionWatchRule)->some View {
        VStack(alignment:.leading,spacing:11) {
            HStack(spacing:10) {
                if let stream = streams.first(where:{$0.id == rule.stream}) {BrandMark(stream:stream,size:22)}
                VStack(alignment:.leading,spacing:5) {
                    Text(streams.first(where:{$0.id == rule.stream})?.name ?? rule.stream).font(.system(size:13,weight:.semibold))
                    Text(rule.windowName+" 잔여 \(Int(rule.below))% 이하").font(.system(size:11)).foregroundStyle(Ink.secondary)
                }
                Spacer()
                if rule.active {
                    Button(cancelling == rule.id ? "취소 중…" : "알림 취소"){cancel(rule)}.buttonStyle(TeumActionStyle()).disabled(cancelling != nil)
                } else {Text(rule.state == "delivered" ? "전달 완료" : rule.state == "cancelled" ? "취소됨" : "만료됨").font(.system(size:10)).foregroundStyle(Ink.secondary)}
            }
            Text(rule.message).font(.system(size:12)).fixedSize(horizontal:false,vertical:true)
            HStack {
                Text(rule.host+" · "+String(rule.session.prefix(12))+"…").help(rule.session)
                Spacer()
                Text("만료 "+Date(timeIntervalSince1970:rule.expiresAt).formatted(.dateTime.month(.defaultDigits).day().hour().minute()))
            }.font(.system(size:10)).foregroundStyle(Ink.secondary)
            Rectangle().fill(Ink.rule).frame(height:0.5).padding(.top,5)
        }.padding(.vertical,7)
    }
    private func reload() {
        if let previewRules {rules = previewRules;return}
        let file = directory.appendingPathComponent("session-watches.json")
        guard FileManager.default.fileExists(atPath:file.path) else {rules = [];return}
        struct StateFile:Decodable {var rules:[SessionWatchRule]}
        let decoder = JSONDecoder();decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {rules = try decoder.decode(StateFile.self,from:Data(contentsOf:file)).rules;error = nil}
        catch {self.error = "세션 알림을 읽지 못했어요. ‘다시 확인’을 눌러 주세요."}
    }
    private func cancel(_ rule:SessionWatchRule) {
        guard previewRules == nil else {rules.removeAll{$0.id == rule.id};return}
        cancelling = rule.id;error = nil
        Task {
            let dir = directory
            let ok = await Task.detached(priority:.utility) {
                SessionWatchStore.cancel(rule.id,directory:dir)
            }.value
            cancelling = nil
            if ok {reload()} else {error = "알림을 취소하지 못했어요. 저장 폴더 접근 상태를 확인해 주세요."}
        }
    }
}
