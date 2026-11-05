import Foundation
@testable import QuotaCore

@main struct ClaudePlanNameTests {
    static func main() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:home,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:home)}
        let identity = ClaudeProvider.Identity(email:"fixture@example.test",accountID:"account-a",organizationID:"org-a")
        func write(_ account:[String:Any]) throws {try JSONSerialization.data(withJSONObject:["oauthAccount":account]).write(to:home.appendingPathComponent(".claude.json"))}
        func plan()->String? {LocalCredentials.claudeConfigPlan(identity:identity,home:home)}
        try write(["accountUuid":"account-a","organizationUuid":"org-a","planDisplayName":"Ultra","organizationRateLimitTier":"default_claude_max_20x"])
        precondition(plan() == "Ultra")
        try write(["accountUuid":"account-a","organizationUuid":"org-a","planDisplayName":" New Plan "])
        precondition(plan() == "New Plan")
        for account:[String:Any] in [
            ["accountUuid":"account-b","organizationUuid":"org-a","planDisplayName":"Ultra"],
            ["accountUuid":"account-a","organizationUuid":"org-b","planDisplayName":"Ultra"],
            ["emailAddress":"fixture@example.test","planDisplayName":"Ultra"],
            ["accountUuid":"account-a","organizationUuid":"org-a","planDisplayName":"  "],
            ["accountUuid":"account-a","organizationUuid":"org-a","organizationRateLimitTier":"default_claude_max_20x"]
        ] {try write(account);precondition(plan() == nil)}
        print("PASS Claude plan: current name, later rename, other account/org, missing identity, blank/missing label")
    }
}
