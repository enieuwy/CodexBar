import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct MusePluginTests {
    static let account = #"""
    {
      "api_key":"LLM|fixture-inference-key", "payment_method":"Visa-0000",
      "require_payment":false, "is_subs_active":true, "user_email":"ada@example.com",
      "subs_tier_name":"Muse Code Power Usage",
      "subs_usage":{
        "window":{"used_percent":96,"window_duration_mins":300,"resets_at":1788599502},
        "weekly":{"used_percent":40,"resets_at":1788739200}
      }
    }
    """#

    static let activeWithoutWindows = #"""
    {"is_subs_active":true,"user_email":"ada@example.com","subs_tier_name":"Muse Code Power Usage"}
    """#

    static let activeWithNullWindows = #"""
    {
      "is_subs_active":true, "user_email":"ada@example.com",
      "subs_tier_name":"Muse Code Power Usage", "subs_usage":null
    }
    """#

    @Test(arguments: BundledPluginTestSupport.engines)
    func `reported subscription windows retain their identity and resets`(
        engine: ProviderPluginEngineKind) async throws
    {
        let snapshot = try await Self.fetch(Self.account, engine: engine)
        #expect(snapshot.primary?.usedPercent == 96)
        #expect(snapshot.primary?.windowMinutes == 300)
        #expect(snapshot.primary?.resetsAt == Date(timeIntervalSince1970: 1_788_599_502))
        #expect(snapshot.secondary?.usedPercent == 40)
        #expect(snapshot.secondary?.windowMinutes == 10080)
        #expect(snapshot.secondary?.resetsAt == Date(timeIntervalSince1970: 1_788_739_200))
        #expect(snapshot.identity?.providerID == .muse)
        #expect(snapshot.identity?.accountEmail == "ada@example.com")
        #expect(snapshot.identity?.loginMethod == "Muse Code Power Usage")
        #expect(snapshot.dataConfidence == .exact)
        #expect(snapshot.providerCost == nil)
        #expect(!snapshot.details.flatMap(\.rows).contains { $0.value.contains("Visa") || $0.value.contains("LLM|") })
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `JSON request sends only the device credential and fixed API version`(
        engine: ProviderPluginEngineKind) async throws
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "muse",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                #expect(request.url?.absoluteString == "https://api.meta.ai/muse-code/key")
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer dca:fixture-token")
                #expect(request.value(forHTTPHeaderField: "x-api-version") == "1.0.0")
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
                #expect(request.timeoutInterval == 15)
                #expect(request.httpBody == Data("{}".utf8))
                return try Self.response(request, body: Self.account)
            })
        _ = try await runtime.fetchUsage(secrets: ["MUSE_DEVICE_TOKEN": "dca:fixture-token"])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `inference keys never reach the mint endpoint`(engine: ProviderPluginEngineKind) async throws {
        let runtime = try BundledPluginTestSupport.runtime(
            "muse",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                Issue.record("Inference credential reached the transport")
                return try Self.response(request, body: Self.account)
            })
        await Self.expectFailure(.authenticationExpired) {
            try await runtime.fetchUsage(secrets: ["MUSE_DEVICE_TOKEN": "LLM|fixture-token"])
        }
    }

    @Test(arguments: ["{}", "<html>Sign in</html>", ""], BundledPluginTestSupport.engines)
    func `unauthorized text responses retain login recovery`(body: String, engine: ProviderPluginEngineKind) async {
        await Self.expectFailure(.authenticationExpired) {
            try await Self.fetch(body, engine: engine, status: 401)
        }
    }

    @Test(arguments: [
        #"{"require_payment":true,"is_subs_active":false}"#,
        #"{"is_subs_active":false,"subs_usage":null}"#,
    ], BundledPluginTestSupport.engines)
    func `inactive subscriptions and missing billing never invent quotas`(
        body: String,
        engine: ProviderPluginEngineKind) async
    {
        await Self.expectFailure(.permissionDenied) { try await Self.fetch(body, engine: engine) }
    }

    @Test(arguments: [Self.activeWithoutWindows, Self.activeWithNullWindows], BundledPluginTestSupport.engines)
    func `active login without quota windows keeps plan identity`(
        body: String,
        engine: ProviderPluginEngineKind) async throws
    {
        let snapshot = try await Self.fetch(body, engine: engine)
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.dataConfidence == .unknown)
        #expect(snapshot.identity?.accountEmail == "ada@example.com")
        #expect(snapshot.identity?.loginMethod == "Muse Code Power Usage")
        let rows = snapshot.details.flatMap(\.rows)
        #expect(rows.contains { $0.label == "Plan" && $0.value == "Muse Code Power Usage" })
        #expect(rows.contains { $0.label == "Quota" && $0.value.contains("login response") })
        #expect(!rows.contains { $0.label == "5 hours" || $0.label == "Weekly" })
    }

    @Test(arguments: [#"{"is_subs_active":true,"subs_usage":"window"}"#], BundledPluginTestSupport.engines)
    func `non-object quota payload remains a parse failure`(
        body: String,
        engine: ProviderPluginEngineKind) async
    {
        await Self.expectFailure(.parseFailure) { try await Self.fetch(body, engine: engine) }
    }

    @Test(arguments: ["1e30", "0", "-1", "true", "\"300\""], BundledPluginTestSupport.engines)
    func `invalid durations fail without trapping`(value: String, engine: ProviderPluginEngineKind) async {
        let body = Self.account.replacingOccurrences(
            of: "\"window_duration_mins\":300",
            with: "\"window_duration_mins\":\(value)")
        await Self.expectFailure(.parseFailure) { try await Self.fetch(body, engine: engine) }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `unrepresentable resets preserve reported usage`(engine: ProviderPluginEngineKind) async throws {
        let body = Self.account.replacingOccurrences(of: "1788599502", with: "1e30")
        let snapshot = try await Self.fetch(body, engine: engine)
        #expect(snapshot.primary?.usedPercent == 96)
        #expect(snapshot.primary?.resetsAt == nil)
        #expect(snapshot.secondary?.resetsAt != nil)
    }

    static let teams = #"{"teams":[{"team_id":906954075295332,"team_name":"My Team"}]}"#
    static let me = #"{"userId":"1","email":"Ada@Example.com","accountType":"META_ACCOUNT"}"#

    static let idleWindowQuota = #"""
    {"subscription_quota":{"tier_id":"1","tier":"Muse Code Everyday Usage","as_of":1790341873,
      "window_weighted_limit":"20000000000","window_duration_secs":18000,
      "weekly_weighted_limit":"60000000000","weekly_resets_at":1790553600,
      "window_weighted_used":"0","weekly_weighted_used":"9043782620"}}
    """#

    @Test(arguments: BundledPluginTestSupport.engines)
    func `omitted login quotas fall back to the dev meta ai session`(engine: ProviderPluginEngineKind) async throws {
        let requests = RequestLog()
        let result = try await Self.fetchWithWeb(engine: engine, requests: requests) { path in
            switch path {
            case "/api/auth/me": (Self.me, 200)
            case "/api/portal/teams": (Self.teams, 200)
            case "/api/portal/teams/906954075295332/subscription-quota": (Self.idleWindowQuota, 200)
            default: ("{}", 404)
            }
        }
        let snapshot = result.usage
        #expect(result.sourceLabel == "oauth+web")
        #expect(snapshot.primary?.usedPercent == 0)
        #expect(snapshot.primary?.windowMinutes == 300)
        #expect(snapshot.primary?.resetsAt == nil)
        let weekly = try #require(snapshot.secondary)
        #expect(abs(weekly.usedPercent - 15.07297103) < 0.0001)
        #expect(weekly.windowMinutes == 10080)
        #expect(weekly.resetsAt == Date(timeIntervalSince1970: 1_790_553_600))
        #expect(snapshot.dataConfidence == .exact)
        #expect(snapshot.identity?.loginMethod == "Muse Code Power Usage")
        let rows = snapshot.details.flatMap(\.rows)
        #expect(rows.contains { $0.label == "Weekly" && $0.value == "15%" })
        #expect(!rows.contains { $0.label == "Quota" })
        let web = requests.all.filter { $0.url?.host == "dev.meta.ai" }
        #expect(web.count == 3)
        #expect(web.allSatisfy {
            $0.value(forHTTPHeaderField: "Cookie") == "llama_dev_sess=fixture"
                && $0.value(forHTTPHeaderField: "Authorization") == nil
        })
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `reported login quotas never read the browser session`(engine: ProviderPluginEngineKind) async throws {
        let requests = RequestLog()
        let result = try await Self.fetchWithWeb(engine: engine, account: Self.account, requests: requests) { _ in
            (Self.idleWindowQuota, 200)
        }
        #expect(result.sourceLabel == nil)
        #expect(result.usage.primary?.usedPercent == 96)
        #expect(!requests.all.contains { $0.url?.host == "dev.meta.ai" })
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `teams without a subscription are skipped`(engine: ProviderPluginEngineKind) async throws {
        let result = try await Self.fetchWithWeb(engine: engine) { path in
            switch path {
            case "/api/auth/me": (Self.me, 200)
            case "/api/portal/teams": (#"{"teams":[{"team_id":"11"},{"team_id":"22"}]}"#, 200)
            case "/api/portal/teams/11/subscription-quota": (#"{"subscription_quota":null}"#, 200)
            case "/api/portal/teams/22/subscription-quota": (Self.idleWindowQuota, 200)
            default: ("{}", 404)
            }
        }
        #expect(result.sourceLabel == "oauth+web")
        #expect(result.usage.secondary != nil)
    }

    @Test(arguments: [
        (#"{"error":"Not authenticated"}"#, 401),
        (#"{"subscription_quota":{"window_weighted_limit":"0","window_weighted_used":"0"}}"#, 200),
        ("<html>", 200),
    ], BundledPluginTestSupport.engines)
    func `unusable web quotas keep the login response result`(
        quota: (body: String, status: Int),
        engine: ProviderPluginEngineKind) async throws
    {
        let rejected = RequestLog()
        let result = try await Self.fetchWithWeb(engine: engine, rejected: rejected) { path in
            switch path {
            case "/api/auth/me": (Self.me, 200)
            case "/api/portal/teams": (Self.teams, 200)
            default: quota
            }
        }
        #expect(result.sourceLabel == nil)
        #expect(result.usage.primary == nil)
        #expect(result.usage.secondary == nil)
        #expect(result.usage.identity?.loginMethod == "Muse Code Power Usage")
        #expect(result.usage.details.flatMap(\.rows).contains { $0.label == "Quota" })
        #expect(rejected.domains == (quota.status == 401 ? ["dev.meta.ai"] : []))
    }

    @Test(arguments: [#"{"email":"bob@example.com"}"#, #"{"userId":"1"}"#], BundledPluginTestSupport.engines)
    func `a browser session for another account never supplies quotas`(
        me: String,
        engine: ProviderPluginEngineKind) async throws
    {
        let requests = RequestLog()
        let result = try await Self.fetchWithWeb(engine: engine, requests: requests) { path in
            switch path {
            case "/api/auth/me": (me, 200)
            case "/api/portal/teams": (Self.teams, 200)
            default: (Self.idleWindowQuota, 200)
            }
        }
        #expect(result.usage.secondary == nil)
        #expect(result.usage.identity?.accountEmail == "ada@example.com")
        #expect(!requests.all.contains { $0.url?.path.hasPrefix("/api/portal") == true })
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `disabled browser cookies never contact dev meta ai`(engine: ProviderPluginEngineKind) async throws {
        let requests = RequestLog()
        let result = try await Self.fetchWithWeb(engine: engine, cookieSource: .off, requests: requests) { _ in
            (Self.idleWindowQuota, 200)
        }
        #expect(result.usage.secondary == nil)
        #expect(!requests.all.contains { $0.url?.host == "dev.meta.ai" })
    }

    @Test(arguments: [
        (ProviderConfig?.none, ProviderCookieSource.off),
        (ProviderConfig(id: .muse), .off),
        (ProviderConfig(id: .muse, cookieHeader: "llama_dev_sess=fixture"), .manual),
        (ProviderConfig(id: .muse, cookieSource: .auto), .auto),
    ])
    func `browser session access stays off until configured`(
        config: ProviderConfig?,
        expected: ProviderCookieSource) throws
    {
        let contribution = try #require(MuseProviderDescriptor.descriptor.settingsSection
            .credentialContribution(context: ProviderCredentialSettingsContext(config: config, account: nil)))
        let settings = ProviderSettingsSnapshot(contributions: [contribution])
        #expect(settings[MuseProviderSettingsKey.self]?.cookieSource == expected)
    }

    private final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        private var rejectedDomains: [String] = []
        var all: [URLRequest] {
            self.lock.withLock { self.requests }
        }

        var domains: [String] {
            self.lock.withLock { self.rejectedDomains }
        }

        func append(_ request: URLRequest) {
            self.lock.withLock { self.requests.append(request) }
        }

        func reject(_ domain: String) {
            self.lock.withLock { self.rejectedDomains.append(domain) }
        }
    }

    private static func fetchWithWeb(
        engine: ProviderPluginEngineKind,
        account: String = Self.activeWithoutWindows,
        cookieSource: ProviderCookieSource = .auto,
        requests: RequestLog = RequestLog(),
        rejected: RequestLog = RequestLog(),
        web: @escaping @Sendable (String) -> (String, Int)) async throws -> ProviderPluginResult
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "muse",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                requests.append(request)
                guard request.url?.host == "dev.meta.ai" else {
                    return try Self.response(request, body: account)
                }
                let (body, status) = web(request.url?.path ?? "")
                return try Self.response(request, body: body, status: status)
            })
        return try await runtime.fetchResult(
            secrets: ["MUSE_DEVICE_TOKEN": "dca:fixture-token"],
            now: Date(timeIntervalSince1970: 1_790_341_873),
            cookieSource: cookieSource,
            cookieInvalidator: { rejected.reject($0) },
            cookieResolver: { _, domain in
                #expect(domain == "dev.meta.ai")
                return "llama_dev_sess=fixture"
            })
    }

    static func fetch(
        _ body: String,
        engine: ProviderPluginEngineKind,
        status: Int = 200) async throws -> UsageSnapshot
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "muse",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                try Self.response(request, body: body, status: status)
            })
        return try await runtime.fetchUsage(
            secrets: ["MUSE_DEVICE_TOKEN": "dca:fixture-token"],
            now: Date(timeIntervalSince1970: 1_788_580_000))
    }

    private static func response(
        _ request: URLRequest,
        body: String,
        status: Int = 200) throws -> (Data, URLResponse)
    {
        let response = try #require(HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]))
        return (Data(body.utf8), response)
    }

    private static func expectFailure(
        _ kind: ProviderFetchClassifiedError.Kind,
        operation: () async throws -> UsageSnapshot) async
    {
        do {
            _ = try await operation()
            Issue.record("Expected \(kind.rawValue)")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == kind)
        } catch {
            Issue.record("Unexpected failure: \(error)")
        }
    }
}
