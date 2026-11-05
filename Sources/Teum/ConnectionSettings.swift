import SwiftUI
import AppKit
import QuotaCore

enum ConnectionAction {
    static func executable(_ name:String)->String? {
        let roots = [NSHomeDirectory()+"/.local/bin","/opt/homebrew/bin","/usr/local/bin","/usr/bin"]
        return roots.map{$0+"/"+name}.first{FileManager.default.isExecutableFile(atPath:$0)}
    }
    static func quote(_ text:String)->String {"'"+text.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    static func loginCommand(_ stream:Stream)->String? {
        switch stream.source {
        case "claude":return executable("claude").map{quote($0)+" auth login"}
        case "codex":
            guard let path = executable("codex") else{return nil}
            let home = NSHomeDirectory()+(stream.profile.isEmpty ? "/.codex" : "/.codex-"+stream.profile)
            return "CODEX_HOME="+quote(home)+" "+quote(path)+" login"
        case "kiro":return executable("kiro-cli").map{quote($0)+" login"}
        default:return nil
        }
    }
    static func app(_ source:String)->URL? {
        let name = source == "agy" ? "Antigravity" : "Grok Bot"
        return ["/Applications/",NSHomeDirectory()+"/Applications/"].map{URL(fileURLWithPath:$0+name+".app")}.first{FileManager.default.fileExists(atPath:$0.path)}
    }
    static func installed(_ stream:Stream)->Bool {
        ["agy","grok"].contains(stream.source) ? app(stream.source) != nil : loginCommand(stream) != nil
    }
    @MainActor static func open(_ stream:Stream)throws {
        if let command = loginCommand(stream) {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Teum-connect",isDirectory:true)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let file = folder.appendingPathComponent("Teum-"+UUID().uuidString+".command")
            // Only invoked by the user's connection button. CLI performs its
            // own login flow; no token is copied, logged or sent to Teum.
            let script = "#!/bin/zsh\nexport PATH=\"$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\"\nprintf '\\nTeum · 연결을 완료한 뒤 앱에서 다시 확인을 눌러 주세요.\\n\\n'\n"+command+"\nprintf '\\n이 창을 닫아도 됩니다.\\n'\n"
            try Data(script.utf8).write(to:file,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:file.path)
            guard NSWorkspace.shared.open(file) else {throw CocoaError(.fileReadUnknown)}
        } else if let url = app(stream.source) {
            NSWorkspace.shared.openApplication(at:url,configuration:NSWorkspace.OpenConfiguration())
        } else {throw CocoaError(.fileNoSuchFile)}
    }
}

struct ConnectionSettings:View {
    @ObservedObject var store:QuotaStore
    @State private var message:String?
    @State private var working = false
    @State private var claudeNeedsPermission = false
    @State private var grokNeedsPermission = false
    private var services:[Stream] {store.prefs.streams.filter{$0.id != "agy-general"}}
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack {
                Text("로그인은 각 서비스가 진행합니다. 완료하면 사용량을 다시 확인하세요.").font(.system(size:11)).foregroundStyle(Ink.secondary)
                Spacer()
                Button("프로필 찾기") {let count = store.discoverProfiles();message = count > 0 ? "코덱스 프로필 \(count)개를 추가했습니다." : "새 코덱스 프로필이 없어요."}.buttonStyle(TeumActionStyle())
                Button(store.refreshing ? "확인 중…" : "모두 다시 확인") {Task{await store.refresh()}}.buttonStyle(TeumActionStyle()).disabled(store.refreshing)
            }.padding(.bottom,17)
            ForEach(services) {s in
                let reading = store.readings[s.id] ?? Reading()
                let ready = ConnectionAction.installed(s)
                VStack(alignment:.leading,spacing:11) {
                    HStack(alignment:.top,spacing:11) {
                        BrandMark(stream:s,size:24).frame(width:28).padding(.top,2)
                        VStack(alignment:.leading,spacing:5) {
                            Text(s.source == "agy" ? "Antigravity · AGY" : s.name).font(.system(size:13,weight:.semibold))
                            Text(detail(s)).font(.system(size:10)).foregroundStyle(Ink.secondary)
                            HStack(spacing:5) {
                                Circle().fill(reading.snapshot != nil && reading.error == nil ? Color.green.opacity(0.8) : Ink.amber).frame(width:4,height:4)
                                Text(s.connected == false ? "Teum 연결 해제됨" : reading.loading ? "사용량 확인 중" : reading.error != nil ? "연결 확인 필요" : reading.snapshot == nil ? "아직 사용량 없음" : "사용량 연결됨")
                                if let account = reading.snapshot?.account {Text("· "+account).lineLimit(1).truncationMode(.middle)}
                            }.font(.system(size:10)).foregroundStyle(Ink.secondary)
                        }.frame(maxWidth:.infinity,alignment:.leading)
                        Button(s.source == "grok" ? "Grok Bot 열기" : s.source == "agy" ? "로그인 앱" : "다시 로그인") {
                            do {try ConnectionAction.open(s);message = "로그인을 완료한 뒤 ‘모두 다시 확인’을 눌러 주세요."}
                            catch {message = "앱 또는 CLI를 열지 못했어요. 설치 경로를 확인해 주세요."}
                        }.buttonStyle(TeumActionStyle()).disabled(!ready)
                        Button(s.connected == false ? "사용량 연결" : "연결 끊기") {
                            Task {
                                working = true;defer{working = false}
                                if s.connected == false {
                                    do {
                                        if s.source == "grok" {try await GrokNative.connect(directory:store.directory)}
                                        store.setConnected(s.id,true);await store.refresh();message = "Teum 사용량 조회를 다시 연결했습니다."
                                    } catch {message = Collector.message(error,source:s.source)}
                                } else {
                                    if s.source == "grok" {GrokNative.disconnect(directory:store.directory);await GrokDashboard.disconnect(directory:store.directory)}
                                    store.setConnected(s.id,false);message = "Teum 조회를 중단했습니다. CLI 로그인은 유지됩니다."
                                }
                            }
                        }.buttonStyle(TeumActionStyle()).disabled(store.refreshing || working)
                    }
                    if !ready {Text("이 Mac에 설치된 CLI 또는 앱을 찾지 못했어요.").font(.system(size:10)).foregroundStyle(Ink.amber).padding(.leading,39)}
                    if s.source == "claude",claudeNeedsPermission {
                        Button("키체인 연결 허용") {Task{_ = await LocalCredentials.authorizeClaudeAccessAsync();await store.refresh()}}.buttonStyle(TeumActionStyle()).padding(.leading,39)
                    }
                    if s.source == "grok" {
                        HStack(spacing:9) {
                            Button(GrokNative.enabled(directory:store.directory) ? "직접 조회 확인" : "앱으로 직접 연결") {
                                message = "Grok Bot 로그인으로 사용량을 확인하고 있습니다…"
                                Task {
                                    working = true;defer{working = false}
                                    if grokNeedsPermission {_ = await GrokBot.authorizeAsync()}
                                    do {try await GrokNative.connect(directory:store.directory);store.setConnected(s.id,true);await store.refresh();message = "Grok Bot 직접 조회를 연결했습니다."}
                                    catch {message = Collector.message(error,source:"grok")}
                                }
                            }.buttonStyle(TeumActionStyle()).disabled(!ready || store.refreshing || working)
                            Text("Grok Bot 앱 로그인 · 브라우저 없이 사용량만 조회").font(.system(size:10)).foregroundStyle(Ink.secondary)
                        }.padding(.leading,39)
                        if !GrokNative.enabled(directory:store.directory) {
                            Button("Aevo 대시보드로 연결") {Task {
                                working = true;defer{working = false}
                                do {_ = try await GrokDashboard.connect(directory:store.directory);store.setConnected(s.id,true);await store.refresh();message = "Aevo 대시보드를 연결했습니다."}
                                catch {message = GrokDashboard.message(error)}
                            }}.buttonStyle(TeumActionStyle()).disabled(GrokDashboard.executable == nil || store.refreshing || working).padding(.leading,39)
                        }
                    }
                    if s.source == "grok",grokNeedsPermission {
                        Button("Grok Bot 키체인 연결 허용") {Task{_ = await GrokBot.authorizeAsync();await store.refresh()}}.buttonStyle(TeumActionStyle()).padding(.leading,39)
                    }
                    if let error = reading.error {Text(error).font(.system(size:10)).foregroundStyle(Ink.amber).fixedSize(horizontal:false,vertical:true).padding(.leading,39)}
                }.padding(.vertical,17)
                Rectangle().fill(Ink.rule).frame(height:0.5)
            }
            if let message {Text(message).font(.system(size:11)).foregroundStyle(Ink.secondary).padding(.top,17).transition(.opacity)}
            Text("AGY 두 모델 한도는 같은 로그인을 공유합니다. 코덱스는 이 Mac에서 감지한 프로필마다 따로 연결합니다.").font(.system(size:11)).foregroundStyle(Ink.secondary).fixedSize(horizontal:false,vertical:true).padding(.top,20)
        }.animation(Motion.feedback,value:message)
            .task(id:store.lastRefresh) {
                guard !store.ephemeral else{return}
                let flags = await Task.detached { (LocalCredentials.claudeCredentialState() == .needsAuthorization,GrokBot.sessionState() == .needsAuthorization) }.value
                claudeNeedsPermission = flags.0;grokNeedsPermission = flags.1
            }
    }
    private func detail(_ s:Stream)->String {
        switch s.source {
        case "claude":return "Claude Code CLI · 구독 로그인"
        case "codex":return "Codex CLI · "+(s.profile.isEmpty ? "기본 프로필" : s.profile+" 전용 프로필")
        case "agy":return "AGY CLI · Antigravity 앱 로그인 공유"
        case "grok":return GrokNative.enabled(directory:store.directory) ? "현재 연결: Grok Bot · 직접 API" : GrokDashboard.connected(directory:store.directory) ? "현재 연결: 공식 Grok 대시보드 · Aevo" : "Grok Bot 앱 로그인 또는 공식 대시보드 연결"
        default:return "Kiro CLI · Builder ID 또는 조직 로그인"
        }
    }
}
