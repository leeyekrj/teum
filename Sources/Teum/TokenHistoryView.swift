import SwiftUI
import Charts
import QuotaCore

struct TokenHistoryView:View {
    @ObservedObject var history:TokenHistoryStore
    let streams:[Stream]
    @State private var selectedDay:Date?
    @State private var selectedHour:Int?
    init(history:TokenHistoryStore,streams:[Stream],initialDay:Date? = nil,initialHour:Int? = nil) {
        self.history = history;self.streams = streams;_selectedDay = State(initialValue:initialDay);_selectedHour = State(initialValue:initialHour)
    }
    var body:some View {
        let report = history.report()
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                controls
                if history.openingCache || (history.lastRead == nil && history.reading) {
                    VStack(spacing:13) {
                        ProgressView().controlSize(.small)
                        Text("로컬 사용 기록을 읽고 있어요").font(.system(size:13,weight:.medium))
                        Text("처음에는 기록량에 따라 시간이 걸립니다.").font(.system(size:11)).foregroundStyle(Ink.secondary)
                    }.frame(maxWidth:.infinity).padding(.vertical,65)
                } else if !history.hasData {
                    VStack(alignment:.leading,spacing:12) {
                        Image(systemName:"chart.bar.xaxis").font(.system(size:23)).foregroundStyle(Ink.secondary)
                        Text("아직 읽을 수 있는 토큰 기록이 없어요").font(.system(size:14,weight:.medium))
                        Text("Claude Code · Codex · OpenCode의 이 Mac 기록을 읽습니다. CLI에서 작업한 뒤 새로고침해 주세요.").font(.system(size:11)).foregroundStyle(Ink.secondary).fixedSize(horizontal:false,vertical:true)
                    }.padding(.vertical,40)
                } else {
                    headline(report)
                    tokenSplit(report.total)
                    dailyChart(report)
                    HStack(spacing:7) {
                        sectionButton("모델별",key:"models")
                        sectionButton("프로젝트",key:"projects")
                        sectionButton(history.period == .today ? "시간별" : "날짜별",key:"days")
                        Spacer()
                        Text("\(report.activeDays)일 활동").font(.system(size:10)).foregroundStyle(Ink.secondary)
                    }
                    if history.breakdown == "models" {models(report)}
                    else if history.breakdown == "projects" {projects(report)}
                    else if history.period == .today {hourRows(report)}
                    else {days(report)}
                    Text("총 토큰에는 캐시 읽기·쓰기가 포함됩니다. 구독으로 사용한 토큰도 집계하며, API 실제 청구 내역을 뜻하지 않습니다.").font(.system(size:10)).foregroundStyle(Ink.secondary).fixedSize(horizontal:false,vertical:true)
                }
                if let error = history.error {Text(error).font(.system(size:10)).foregroundStyle(Ink.amber)}
                Text("보관된 기록만 표시합니다. 빈 날짜가 실제 사용량 0을 뜻하지는 않습니다.").font(.system(size:9)).foregroundStyle(Ink.secondary)
                Text((history.cache.importedUsageScopeDays ?? 0)>0 ? "로컬 CLI 로그 · QuotaBar · UsageScope 보관 집계 포함" : (history.cache.importedArchiveDays ?? 0)>0 ? "로컬 CLI 로그 · QuotaBar 보관 집계 포함" : "지원 로그 · Claude Code / Codex 프로필 / OpenCode").font(.system(size:9)).foregroundStyle(Ink.secondary)
            }.padding(.horizontal,36).padding(.top,4).padding(.bottom,20)
        }.scrollIndicators(.hidden)
            // Loading starts when the page becomes current (PageCarousel), not on mount.
            // Only the first-load placeholder fades: animating every text change would
            // redraw the numbers on the CPU for each frame of the curve.
            .animation(Motion.feedback,value:history.openingCache || (history.lastRead == nil && history.reading))
    }
    private var controls:some View {
        HStack(spacing:5) {
            ForEach(TokenPeriod.allCases,id:\.rawValue) {period in
                Button {history.period = period;history.selectedMonth = nil;selectedDay = nil;selectedHour = nil} label: {
                    Text(period.title).font(.system(size:11,weight:.medium)).padding(.horizontal,11).frame(height:28)
                        .background(Color.white.opacity(history.period == period && history.selectedMonth == nil ? 0.11 : 0.025),in:RoundedRectangle(cornerRadius:7))
                        .animation(Motion.feedback,value:history.period == period && history.selectedMonth == nil)
                        .contentShape(Rectangle())
                }.buttonStyle(TeumPressStyle()).accessibilityAddTraits(history.period == period && history.selectedMonth == nil ? [.isSelected] : [])
            }
            Spacer()
            Menu {
                Button("전체 기간") {history.period = .all;history.selectedMonth = nil;selectedDay = nil}
                ForEach(history.months,id:\.self) {month in
                    Button(month) {history.period = .all;history.selectedMonth = month;selectedDay = nil}
                }
            } label:{Text(history.selectedMonth ?? "월별 기록").font(.system(size:10))}
                .menuStyle(.borderlessButton).fixedSize().foregroundStyle(Ink.secondary).help("보관된 과거 월을 따로 보기")
        }
    }
    private func headline(_ report:TokenReport)->some View {
        HStack(alignment:.firstTextBaseline,spacing:8) {
            Text(TokenText.count(report.total.allTokens)).font(.system(size:29,weight:.semibold)).monospacedDigit().contentTransition(.numericText())
            Text("토큰 · 캐시 포함").font(.system(size:11)).foregroundStyle(Ink.secondary)
            Spacer()
            if report.sessions>0 {Text("\(report.sessions.formatted())세션").font(.system(size:11)).foregroundStyle(Ink.secondary)}
        }.help("총 \(report.total.allTokens.formatted()) 토큰")
    }
    private func tokenSplit(_ entry:ArchiveEntry)->some View {
        HStack(spacing:0) {
            tokenField("입력",entry.input)
            tokenField("출력",entry.output)
            tokenField("캐시 읽기",entry.cacheRead)
            tokenField("캐시 쓰기",entry.cacheWrite)
        }.padding(.bottom,4)
    }
    private func tokenField(_ title:String,_ count:Int)->some View {
        VStack(alignment:.leading,spacing:6) {
            Text(title).font(.system(size:10)).foregroundStyle(Ink.secondary)
            Text(TokenText.count(count)).font(.system(size:14,weight:.medium)).monospacedDigit()
        }.frame(maxWidth:.infinity,alignment:.leading).help("\(title) \(count.formatted()) 토큰")
    }
    @ViewBuilder private func dailyChart(_ report:TokenReport)->some View {
        if history.period == .today {hourChart(report)} else {dateChart(report)}
    }
    private func hourChart(_ report:TokenReport)->some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {
                Text("시간별 토큰").font(.system(size:11,weight:.medium))
                Spacer()
                if let hour = selectedHour,let bucket = report.hourly.first(where:{$0.hour == hour}) {
                    Text("\(hour)–\(hour+1)시 · "+TokenText.count(bucket.tokens)).font(.system(size:10)).monospacedDigit().foregroundStyle(Ink.secondary)
                }
            }
            Chart(report.hourly) {bucket in
                BarMark(x:.value("시",Double(bucket.hour)),y:.value("토큰",bucket.tokens),width:.fixed(9))
                    .foregroundStyle(selectedHour == bucket.hour ? Ink.text : Color(red:0.49,green:0.80,blue:0.71).opacity(selectedHour == nil ? 1 : 0.55)).cornerRadius(2)
            }.chartXScale(domain:-0.5...23.5,range:.plotDimension(padding:12))
                .chartYScale(domain:0...max(1,Double(report.hourly.map(\.tokens).max() ?? 0)*1.15))
                .chartYAxis {
                    AxisMarks(position:.leading,values:.automatic(desiredCount:3)) {value in
                        AxisGridLine().foregroundStyle(Ink.rule)
                        AxisValueLabel {
                            if let n = value.as(Int.self) {
                                Text(TokenText.count(n).replacingOccurrences(of:"\\.?0+([KMB])$",with:"$1",options:.regularExpression))
                                    .font(.system(size:9)).monospacedDigit().foregroundStyle(Ink.secondary)
                            }
                        }
                    }
                }.chartXAxis {
                    AxisMarks(values:[0.0,6.0,12.0,18.0]) {value in
                        AxisValueLabel(anchor:.top,collisionResolution:.disabled) {
                            if let hour = value.as(Double.self) {
                                Text("\(Int(hour))시").font(.system(size:10,weight:selectedHour == Int(hour) ? .semibold : .regular))
                                    .monospacedDigit().foregroundStyle(selectedHour == Int(hour) ? Ink.text : Ink.secondary).fixedSize()
                            }
                        }
                    }
                }.frame(height:120)
                .chartOverlay {proxy in
                    GeometryReader {geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle()).onContinuousHover {phase in
                            switch phase {
                            case .active(let point):
                                if let frame = proxy.plotFrame,geometry[frame].contains(point),let hour:Double = proxy.value(atX:point.x-geometry[frame].origin.x) {
                                    let next = max(0,min(23,Int(hour.rounded())));if next != selectedHour {selectedHour = next}
                                } else {selectedHour = nil}
                            case .ended:selectedHour = nil
                            }
                        }
                    }
                }
        }
    }
    private func hourRows(_ report:TokenReport)->some View {
        VStack(spacing:0) {
            ForEach(report.hourly) {bucket in
                HStack {
                    Text(String(format:"%02d:00–%02d:00",bucket.hour,bucket.hour+1)).font(.system(size:11)).monospacedDigit()
                    Spacer()
                    Text(TokenText.count(bucket.tokens)).font(.system(size:12,weight:.medium)).monospacedDigit().foregroundStyle(bucket.tokens>0 ? Ink.text : Ink.secondary)
                }.frame(height:33)
                Rectangle().fill(Ink.rule).frame(height:0.5)
            }
        }
    }
    private func dateChart(_ report:TokenReport)->some View {
        let first = report.daily.first?.day ?? Calendar.current.startOfDay(for:.now)
        let last = report.daily.last?.day ?? first
        let count = report.daily.count
        let indexes = count <= 7 ? Array(report.daily.indices) : Array(Set([0,(count-1)/3,2*(count-1)/3,count-1])).sorted()
        let ticks = indexes.map(Double.init)
        let ceiling = max(1,Double(report.daily.map(\.tokens).max() ?? 0)*1.15)
        return VStack(alignment:.leading,spacing:8) {
            HStack {
                Text("날짜별 토큰").font(.system(size:11,weight:.medium))
                Spacer()
                if let day = selectedDay,let bucket = report.daily.first(where:{Calendar.current.isDate($0.day,inSameDayAs:day)}) {
                    Text(bucket.day.formatted(.dateTime.month(.defaultDigits).day().weekday())+" · "+TokenText.count(bucket.tokens)).font(.system(size:10)).monospacedDigit().foregroundStyle(Ink.secondary)
                } else {
                    Text(first.formatted(.dateTime.month(.defaultDigits).day())+"–"+last.formatted(.dateTime.month(.defaultDigits).day())).font(.system(size:10)).foregroundStyle(Ink.secondary)
                }
            }
            // One numeric slot per calendar day. Date bin centres and midnight
            // axis ticks are different positions in Swift Charts; sharing a slot
            // keeps bars, labels and hover selection on the very same centre.
            Chart(report.daily.indices,id:\.self) {index in
                let day = report.daily[index]
                BarMark(x:.value("날짜",Double(index)),y:.value("토큰",day.tokens),width:.fixed(count<=7 ? 22 : count<=30 ? 7 : 3))
                    .foregroundStyle(selectedDay == day.day ? Ink.text : Color(red:0.49,green:0.80,blue:0.71).opacity(selectedDay == nil ? 1 : 0.55)).cornerRadius(2)
                    .accessibilityLabel(day.day.formatted(.dateTime.month(.defaultDigits).day().weekday()))
                    .accessibilityValue("\(day.tokens.formatted()) 토큰")
            }.chartXScale(domain:-0.5...Double(max(1,count))-0.5,range:.plotDimension(padding:count<=7 ? 0 : 18))
                .chartYScale(domain:0...ceiling)
                .chartYAxis {
                    AxisMarks(position:.leading,values:.automatic(desiredCount:3)) {value in
                        AxisGridLine().foregroundStyle(Ink.rule)
                        AxisValueLabel {
                            if let n = value.as(Int.self) {
                                Text(TokenText.count(n).replacingOccurrences(of:"\\.?0+([KMB])$",with:"$1",options:.regularExpression))
                                    .font(.system(size:9)).monospacedDigit().foregroundStyle(Ink.secondary)
                            }
                        }
                    }
                }.chartXAxis {
                    AxisMarks(values:ticks) {value in
                        AxisValueLabel(anchor:.top,collisionResolution:.disabled) {
                            if let slot = value.as(Double.self),report.daily.indices.contains(Int(slot)) {
                                let date = report.daily[Int(slot)].day
                                let components = Calendar.current.dateComponents([.month,.day],from:date)
                                Text("\(components.month ?? 1)/\(components.day ?? 1)")
                                    .font(.system(size:10,weight:selectedDay == date ? .semibold : .regular))
                                    .monospacedDigit().foregroundStyle(selectedDay == date ? Ink.text : Ink.secondary).fixedSize()
                            }
                        }
                    }
                }.frame(height:120)
                .chartOverlay {proxy in
                    GeometryReader {geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover {phase in
                                switch phase {
                                case .active(let point):
                                    if let frame = proxy.plotFrame,geometry[frame].contains(point),let slot:Double = proxy.value(atX:point.x-geometry[frame].origin.x),!report.daily.isEmpty {
                                        let index = max(0,min(count-1,Int(slot.rounded())))
                                        let next = report.daily[index].day
                                        if selectedDay != next {selectedDay = next}
                                    } else {selectedDay = nil}
                                case .ended:selectedDay = nil
                                }
                            }
                    }
                }
        }
    }
    private func sectionButton(_ title:String,key:String)->some View {
        Button {history.breakdown = key} label:{Text(title).font(.system(size:11,weight:history.breakdown == key ? .semibold : .regular)).foregroundStyle(history.breakdown == key ? Ink.text : Ink.secondary).padding(.horizontal,9).frame(height:27).background(history.breakdown == key ? Color.white.opacity(0.07) : .clear,in:RoundedRectangle(cornerRadius:6)).contentShape(Rectangle())}.buttonStyle(TeumPressStyle()).accessibilityAddTraits(history.breakdown == key ? [.isSelected] : [])
    }
    private func models(_ report:TokenReport)->some View {
        VStack(spacing:0) {
            ForEach(report.models) {row in
                HStack(spacing:9) {
                    sourceIcon(row.source)
                    VStack(alignment:.leading,spacing:5) {
                        Text(row.model).font(.system(size:11,weight:.medium)).lineLimit(1).truncationMode(.middle)
                        Text(row.source.displayName).font(.system(size:9)).foregroundStyle(Ink.secondary)
                    }
                    Spacer(minLength:8)
                    VStack(alignment:.trailing,spacing:5) {
                        Text(TokenText.count(row.entry.allTokens)).font(.system(size:12,weight:.semibold)).monospacedDigit()
                        Text("\(Int((Double(row.entry.allTokens)/Double(max(1,report.total.allTokens))*100).rounded()))%").font(.system(size:9)).foregroundStyle(Ink.secondary)
                    }
                }.frame(height:46).help("입력 \(row.entry.input.formatted()) · 출력 \(row.entry.output.formatted()) · 캐시 \((row.entry.cacheRead+row.entry.cacheWrite).formatted())")
                Rectangle().fill(Ink.rule).frame(height:0.5)
            }
        }
    }
    private func projects(_ report:TokenReport)->some View {
        VStack(spacing:0) {
            if report.projects.isEmpty {Text("프로젝트 정보가 있는 기록이 아직 없어요.").font(.system(size:11)).foregroundStyle(Ink.secondary).frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,18)}
            ForEach(report.projects) {project in
                HStack(spacing:10) {
                    Image(systemName:"folder").font(.system(size:14)).foregroundStyle(Ink.secondary)
                    VStack(alignment:.leading,spacing:5) {
                        Text(project.info.displayName).font(.system(size:11,weight:.medium)).lineLimit(1).truncationMode(.middle)
                        Text("\(project.sessions.formatted())세션 · \(project.activeMinutes.formatted())분 활동").font(.system(size:9)).foregroundStyle(Ink.secondary)
                    }
                    Spacer(minLength:8)
                    Text(TokenText.count(project.tokens)).font(.system(size:12,weight:.semibold)).monospacedDigit()
                }.frame(height:46)
                Rectangle().fill(Ink.rule).frame(height:0.5)
            }
        }
    }
    private func days(_ report:TokenReport)->some View {
        VStack(spacing:0) {
            ForEach(report.daily.reversed()) {day in
                HStack {
                    Text(day.day.formatted(.dateTime.month(.defaultDigits).day().weekday())).font(.system(size:11))
                    Spacer()
                    Text(TokenText.count(day.tokens)).font(.system(size:12,weight:.medium)).monospacedDigit().foregroundStyle(day.tokens>0 ? Ink.text : Ink.secondary)
                }.frame(height:33)
                Rectangle().fill(Ink.rule).frame(height:0.5)
            }
        }
    }
    @ViewBuilder private func sourceIcon(_ source:CostSource)->some View {
        if source == .openCode {Image(systemName:"terminal").font(.system(size:18)).foregroundStyle(Ink.secondary).frame(width:20)}
        else {BrandMark(stream:streams.first(where:{$0.source == (source == .claudeCode ? "claude" : "codex")}) ?? Stream.defaults[source == .claudeCode ? 0 : 1],size:20)}
    }
}
