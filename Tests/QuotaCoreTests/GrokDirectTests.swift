import Foundation
@testable import QuotaCore

@main struct GrokDirectTests {
    static func main() async throws {
        let session = LocalCredentials.CursorSession(sessionCookie:"fixture::test",email:"fixture@example.test",subject:"fixture")
        let good = Data(#"{"hasNonZeroIncludedLimit":true,"usagePercent":30.465872156013003,"currentPeriodStart":"2026-10-30T06:21:31.377Z","nextResetTimestampUtc":"2026-11-06T06:21:31.377Z","cursorPlanName":"Premium","isUnified":true}"#.utf8)
        let value = try await GrokBot.dashboardUsage(session:session,send:{method,url,headers,body,timeout in
            precondition(method == "POST" && url.absoluteString == "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus")
            precondition(headers["Authorization"] == "Bearer test" && body == Data("{}".utf8) && timeout == 12)
            return HTTPResponse(status:200,data:good)
        })
        precondition(abs(value.windows[0].usedPercent! - 30.465872156013003)<0.00001 && value.account == session.email)
        precondition(value.windows[0].id == "Grok weekly usage" && value.windows[0].title == "Grok weekly usage" && value.windows[0].scope == nil && !value.windows[0].extra && value.planName == "Premium")
        for status in [401,403,429,500] {
            do {
                _ = try await GrokBot.dashboardUsage(session:session,send:{_,_,_,_,_ in HTTPResponse(status:status,data:good)})
                fatalError("HTTP failure accepted: \(status)")
            } catch is ProviderError {}
        }
        for text in ["{}", #"{"hasNonZeroIncludedLimit":false,"usagePercent":0}"#, #"{"hasNonZeroIncludedLimit":true,"usagePercent":-1}"#, #"{"hasNonZeroIncludedLimit":true,"usagePercent":0}"#] {
            do {
                _ = try await GrokBot.dashboardUsage(session:session,send:{_,_,_,_,_ in HTTPResponse(status:200,data:Data(text.utf8))})
                fatalError("Invalid quota accepted")
            } catch is ProviderError {}
        }
        print("PASS Grok direct: authenticated usage RPC, weekly values, preserved window ID, 4 HTTP failures, 4 incomplete quota replies")
    }
}
