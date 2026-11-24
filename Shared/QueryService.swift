import Foundation
import CryptoKit

enum QueryError: LocalizedError {
    case missingCredentials(String)
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials(let message): return message
        case .remote(let message): return message
        }
    }
}

/// 三个厂商的用量查询，端点/鉴权/解析与 cc-switch 内置模板及
/// 用户自定义脚本（智谱）保持一致。
enum QueryService {
    static func fetchAll(_ credentials: [ProviderCredentials], timeout: TimeInterval = 12) async -> [ProviderUsage] {
        let results = await withTaskGroup(of: ProviderUsage.self) { group -> [ProviderUsage] in
            for credential in credentials {
                group.addTask { await fetch(credential, timeout: timeout) }
            }
            var collected: [ProviderUsage] = []
            for await result in group { collected.append(result) }
            return collected
        }
        let order: [ProviderKind] = [.volcengine, .zhipu, .deepseek, .openCodeGo, .commandCode]
        var ordered = order.compactMap { kind in results.first { $0.kind == kind } }
        ordered.append(contentsOf: results.filter { !order.contains($0.kind) })
        return ordered
    }

    static func fetch(_ credential: ProviderCredentials, timeout: TimeInterval = 12) async -> ProviderUsage {
        do {
            switch credential.kind {
            case .volcengine: return try await fetchVolc(credential, timeout: timeout)
            case .zhipu: return try await fetchZhipu(credential, timeout: timeout)
            case .deepseek: return try await fetchDeepSeek(credential, timeout: timeout)
            case .openCodeGo: return try await fetchOpenCodeGo(credential, timeout: timeout)
            case .commandCode: return try await fetchCommandCode(credential, timeout: timeout)
            }
        } catch {
            return ProviderUsage(kind: credential.kind, ok: false, errorMessage: error.localizedDescription)
        }
    }

    private static func makeSession(_ timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 5
        return URLSession(configuration: configuration)
    }

    // MARK: - 火山方舟 Coding Plan（OpenAPI V4 签名）

    private static let volcDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static func uriEncode(_ string: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    private static func sha256Hex(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func hmacHex(key: Data, _ message: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key))
        return Data(code).map { String(format: "%02x", $0) }.joined()
    }

    /// V4 签名：HMAC-SHA256（无 AWS4 前缀），scope {date}/{region}/ark/request，
    /// SignedHeaders 固定 host;x-date;x-content-sha256;content-type，空 body。
    private static func volcSignedPOST(region: String, accessKey: String, secretKey: String,
                                       action: String, timeout: TimeInterval) async throws -> (status: Int, json: [String: Any]) {
        let host = "open.volcengineapi.com"
        let contentType = "application/json; charset=utf-8"
        let signedHeaders = "host;x-date;x-content-sha256;content-type"

        var pairs = [("Action", action), ("Region", region), ("Version", "2024-01-01")]
        pairs.sort { $0.0 < $1.0 }
        let canonicalQuery = pairs.map { uriEncode($0.0) + "=" + uriEncode($0.1) }.joined(separator: "&")

        let xDate = volcDateFormatter.string(from: Date())
        let shortDate = String(xDate.prefix(8))
        let bodyHash = sha256Hex("")

        let canonicalHeaders = "host:\(host)\nx-date:\(xDate)\nx-content-sha256:\(bodyHash)\ncontent-type:\(contentType)\n"
        let canonicalRequest = "POST\n/\n\(canonicalQuery)\n\(canonicalHeaders)\n\(signedHeaders)\n\(bodyHash)"
        let scope = "\(shortDate)/\(region)/ark/request"
        let stringToSign = "HMAC-SHA256\n\(xDate)\n\(scope)\n\(sha256Hex(canonicalRequest))"

        let kDate = Data(HMAC<SHA256>.authenticationCode(for: Data(shortDate.utf8), using: SymmetricKey(data: Data(secretKey.utf8))))
        let kRegion = Data(HMAC<SHA256>.authenticationCode(for: Data(region.utf8), using: SymmetricKey(data: kDate)))
        let kService = Data(HMAC<SHA256>.authenticationCode(for: Data("ark".utf8), using: SymmetricKey(data: kRegion)))
        let kSigning = Data(HMAC<SHA256>.authenticationCode(for: Data("request".utf8), using: SymmetricKey(data: kService)))
        let signature = hmacHex(key: kSigning, stringToSign)

        let authorization = "HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"

        var request = URLRequest(url: URL(string: "https://\(host)/?\(canonicalQuery)")!)
        request.httpMethod = "POST"
        request.setValue(xDate, forHTTPHeaderField: "X-Date")
        request.setValue(bodyHash, forHTTPHeaderField: "X-Content-Sha256")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.httpBody = Data()

        let (data, response) = try await makeSession(timeout).data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (status, json)
    }

    /// 解析 QuotaUsage[]（别名 Usages/Details），窗口/百分比/重置时间字段别名容错
    private static func parseVolcPlan(_ json: [String: Any]) -> (windows: [QuotaWindow], error: String?) {
        if let metadata = json["ResponseMetadata"] as? [String: Any],
           let error = metadata["Error"] as? [String: Any] {
            let code = JSONUtil.string(error, "Code") ?? "Error"
            let message = JSONUtil.string(error, "Message") ?? ""
            return ([], "\(code): \(message)")
        }
        let result = (json["Result"] as? [String: Any]) ?? json
        let items = ((result["QuotaUsage"] ?? result["Usages"] ?? result["Details"]) as? [[String: Any]]) ?? []
        var windows: [QuotaWindow] = []
        for item in items {
            guard let level = JSONUtil.string(item, "Level", "Type", "Period", "Label", "Window") else { continue }
            var percent = JSONUtil.double(item, "Percent", "UsedPercent", "UsagePercent")
            let used = JSONUtil.double(item, "Used")
            let total = JSONUtil.double(item, "Total", "Quota")
            if percent == nil, let used, let total, total > 0 { percent = used / total * 100 }
            windows.append(QuotaWindow(
                name: volcWindowName(level),
                percent: ((percent ?? 0) * 10).rounded() / 10,
                used: used, total: total, unit: nil,
                resetTime: JSONUtil.date(item, "ResetTime", "ResetTimestamp")))        }
        windows.sort { $0.percent > $1.percent }
        return (windows, nil)
    }

    private static func volcWindowName(_ level: String) -> String {
        let lowered = level.lowercased()
        if lowered.contains("month") || lowered == "m" || lowered == "30d" { return QuotaWindow.monthly }
        if lowered.contains("week") || lowered == "7d" { return QuotaWindow.weekly }
        if lowered.contains("hour") || lowered == "5h" || lowered.contains("session") { return QuotaWindow.fiveHour }
        return level
    }

    private static func fetchVolc(_ credential: ProviderCredentials, timeout: TimeInterval) async throws -> ProviderUsage {
        guard let accessKey = credential.accessKey, let secretKey = credential.secretKey, let region = credential.region else {
            throw QueryError.missingCredentials("火山 AK/SK 未配置")
        }
        var windows: [QuotaWindow] = []
        var lastError: String?
        // 先探 Coding Plan，再探 Agent Plan（与 cc-switch 的双探策略一致）
        for action in ["GetCodingPlanUsage", "GetAFPUsage"] {
            do {
                let (status, json) = try await volcSignedPOST(
                    region: region, accessKey: accessKey, secretKey: secretKey,
                    action: action, timeout: timeout)
                let parsed = parseVolcPlan(json)
                if !parsed.windows.isEmpty {
                    windows = parsed.windows
                    lastError = nil
                    break
                }
                lastError = parsed.error ?? "HTTP \(status)"
            } catch {
                lastError = error.localizedDescription
            }
        }
        guard !windows.isEmpty else { throw QueryError.remote(lastError ?? "无额度数据") }
        return ProviderUsage(kind: .volcengine, ok: true, windows: windows, subtitle: "Coding Plan")
    }

    // MARK: - 智谱 GLM Coding Plan

    /// 与 cc-switch 中用户自定义脚本一致：
    /// data.limits[] 里 unit:3 → 五小时窗口，unit:6 → 每周窗口，主值取每周（更稳定）。
    private static func fetchZhipu(_ credential: ProviderCredentials, timeout: TimeInterval) async throws -> ProviderUsage {
        guard let apiKey = credential.apiKey else { throw QueryError.missingCredentials("智谱 apiKey 未配置") }
        let urlString = credential.baseUrl ?? "https://open.bigmodel.cn/api/monitor/usage/quota/limit"
        guard let url = URL(string: urlString) else { throw QueryError.remote("智谱 baseUrl 无效") }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "Authorization") // 智谱：裸 key，无 Bearer 前缀
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("en-US,en", forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await makeSession(timeout).data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw QueryError.remote("智谱: 响应解析失败 (HTTP \(status))")
        }
        if let code = JSONUtil.int(json, "code"), code != 200 {
            let message = JSONUtil.string(json, "msg", "message") ?? "HTTP \(status)"
            throw QueryError.remote("智谱: \(message)")
        }
        guard let payload = json["data"] as? [String: Any],
              let limits = payload["limits"] as? [[String: Any]] else {
            throw QueryError.remote("智谱: 未获取到用量数据")
        }

        let level = JSONUtil.string(payload, "level") ?? ""
        var fiveHour: QuotaWindow?
        var weekly: QuotaWindow?
        var fallback: QuotaWindow?
        for limit in limits {
            let type = JSONUtil.string(limit, "type") ?? ""
            let unit = JSONUtil.int(limit, "unit") ?? 0
            let used = JSONUtil.double(limit, "currentValue")
            let total = JSONUtil.double(limit, "usage")
            let percent = JSONUtil.double(limit, "percentage")
                ?? ((used ?? 0) / max(total ?? 1, 1)) * 100
            let window = QuotaWindow(
                name: unit == 3 ? QuotaWindow.fiveHour : QuotaWindow.weekly,
                percent: (percent * 10).rounded() / 10,
                used: used, total: total, unit: "积分",
                resetTime: JSONUtil.date(limit, "nextResetTime", "resetTime"),
                remainingOverride: JSONUtil.double(limit, "remaining"))
            if type == "CREDIT_LIMIT" {
                if unit == 3 { fiveHour = window } else if unit == 6 { weekly = window }
            } else if fallback == nil {
                fallback = window
            }
        }
        guard let main = weekly ?? fiveHour ?? fallback else {
            throw QueryError.remote("智谱: 无 CREDIT_LIMIT 数据")
        }
        var windows = [main]
        if let fiveHour, fiveHour != main { windows.append(fiveHour) }
        if let weekly, weekly != main, !windows.contains(weekly) { windows.append(weekly) }
        return ProviderUsage(kind: .zhipu, ok: true, windows: windows,
                             subtitle: "Coding Plan" + (level.isEmpty ? "" : " (\(level))"))
    }

    // MARK: - DeepSeek 余额

    private static func fetchDeepSeek(_ credential: ProviderCredentials, timeout: TimeInterval) async throws -> ProviderUsage {
        guard let token = credential.bearerToken else { throw QueryError.missingCredentials("DeepSeek API key 未配置") }
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/user/balance")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await makeSession(timeout).data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw QueryError.remote("DeepSeek: 响应解析失败 (HTTP \(status))")
        }
        if status != 200 {
            let message = ((json["error"] as? [String: Any]).flatMap { JSONUtil.string($0, "message") }) ?? "HTTP \(status)"
            throw QueryError.remote("DeepSeek: \(message)")
        }
        let infos = (json["balance_infos"] as? [[String: Any]]) ?? []
        guard let main = infos.first else { throw QueryError.remote("DeepSeek: 无余额数据") }
        return ProviderUsage(
            kind: .deepseek, ok: true,
            subtitle: "余额",
            balance: JSONUtil.double(main, "total_balance") ?? 0,
            currency: JSONUtil.string(main, "currency") ?? "CNY",
            isAvailable: JSONUtil.bool(json, "is_available"))
    }

    // MARK: - OpenCode Go（sk- Key，官方 usage 端点）

    /// `GET https://opencode.ai/zen/go/v1/usage`，`Authorization: Bearer sk-…`
    /// 响应：`{ usage: { rolling|weekly|monthly: { status, percent, resetsAt } } }`，
    /// percent 实测为 0-100 整数（与 PerfPanel 同源口径）。
    private static func fetchOpenCodeGo(_ credential: ProviderCredentials, timeout: TimeInterval) async throws -> ProviderUsage {
        guard let key = credential.apiKey else { throw QueryError.missingCredentials("OpenCode Go API Key 未配置") }
        var request = URLRequest(url: URL(string: "https://opencode.ai/zen/go/v1/usage")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await makeSession(timeout).data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw QueryError.remote("OpenCode Go: 鉴权失败 (HTTP \(status))，请检查 API Key（opencode.ai/console）")
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw QueryError.remote("OpenCode Go: 响应解析失败 (HTTP \(status))")
        }
        if status != 200 {
            let message = ((json["error"] as? [String: Any]).flatMap { JSONUtil.string($0, "message") }) ?? "HTTP \(status)"
            throw QueryError.remote("OpenCode Go: \(message)")
        }
        guard let usage = json["usage"] as? [String: Any] else {
            throw QueryError.remote("OpenCode Go: 响应中没有 usage 字段")
        }

        // 三个滚动窗口；缺失即未订阅该窗口。percent 实测 0-100，防御式兼容 0-1 分数形态
        let spec: [(key: String, name: String)] = [
            ("rolling", QuotaWindow.fiveHour),
            ("weekly", QuotaWindow.weekly),
            ("monthly", QuotaWindow.monthly),
        ]
        var raw: [(String, [String: Any])] = []
        for item in spec {
            if let node = usage[item.key] as? [String: Any] { raw.append((item.name, node)) }
        }
        guard !raw.isEmpty else {
            throw QueryError.remote("OpenCode Go: 响应中没有 rolling/weekly/monthly 窗口")
        }
        let values = raw.map { JSONUtil.double($0.1, "percent") ?? 0 }
        let fraction = values.allSatisfy { $0 >= 0 && $0 <= 1 } && values.contains { $0 > 0 }

        let windows = raw.map { name, node -> QuotaWindow in
            var percent = JSONUtil.double(node, "percent", "usagePercent") ?? 0
            if fraction { percent *= 100 }
            let used = JSONUtil.double(node, "usedDollars", "usageDollars")
            let limit = JSONUtil.double(node, "limitDollars", "limit")
            return QuotaWindow(
                name: name,
                percent: min(max(percent, 0), 100),
                used: used, total: limit, unit: limit == nil ? nil : "USD",
                resetTime: JSONUtil.date(node, "resetsAt", "resetAt", "reset_at"))
        }
        let plan = JSONUtil.string(json, "plan") ?? JSONUtil.string(usage, "plan") ?? ""
        return ProviderUsage(kind: .openCodeGo, ok: true, windows: windows,
                             subtitle: plan.isEmpty ? "Go" : plan)
    }

    // MARK: - CommandCode（GOAT 等套餐，官方 CLI 的 /alpha 私有路由）

    /// 四个端点（与 cc-switch / PerfPanel 实测一致）：
    /// 1. `/alpha/whoami?limits=1` → org.id（个人 Key 常为 null，此时省略 orgId）
    /// 2. `/alpha/billing/credits` → credits.{monthly,purchased,free}Credits + windowLimits.{limited,fiveHour,weekly}
    /// 3. `/alpha/billing/subscriptions` → data.{planId,currentPeriodStart,currentPeriodEnd}
    /// 4. `/alpha/usage/summary?since=` → totalCost（当前周期已花）
    /// 口径：5h/周 = used/cap；月 = totalCost ÷ 三个 credits 池之和；show 剩余池作为「余额」。
    private static let commandCodeBase = "https://api.commandcode.ai"

    private static func fetchCommandCode(_ credential: ProviderCredentials, timeout: TimeInterval) async throws -> ProviderUsage {
        guard let key = credential.apiKey else { throw QueryError.missingCredentials("CommandCode API Key 未配置") }
        let session = makeSession(timeout)

        let who = try await commandCodeGet(key: key, path: "/alpha/whoami?limits=1", session: session)
        let orgID = commandCodeOrgID(who)
        let query: (String...) -> String = { pairs in
            var parts: [String] = []
            if !orgID.isEmpty { parts.append("orgId=\(orgID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? orgID)") }
            parts.append(contentsOf: pairs.filter { !$0.isEmpty })
            return parts.isEmpty ? "" : "?" + parts.joined(separator: "&")
        }

        async let creditsTask = commandCodeGet(key: key, path: "/alpha/billing/credits" + query(), session: session)
        async let subsTask = commandCodeGet(key: key, path: "/alpha/billing/subscriptions" + query(), session: session)
        let (creditsJSON, subsJSON) = try await (creditsTask, subsTask)

        var periodStart = "", planID = ""
        var periodEnd: Date?
        if let sub = subsJSON["data"] as? [String: Any] {
            periodStart = JSONUtil.string(sub, "currentPeriodStart") ?? ""
            periodEnd = JSONUtil.date(sub, "currentPeriodEnd")
            planID = JSONUtil.string(sub, "planId") ?? ""
        }
        let summaryJSON = try await commandCodeGet(key: key, path: "/alpha/usage/summary" + query(
            periodStart.isEmpty ? "" : "since=\(periodStart.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? periodStart)"),
            session: session)

        guard let totalCost = JSONUtil.double(summaryJSON, "totalCost") else {
            throw QueryError.remote("CommandCode: usage/summary 缺少 totalCost 字段（接口口径可能有变）")
        }
        return parseCommandCode(credits: creditsJSON, spent: totalCost,
                                planID: planID, periodEnd: periodEnd)
    }

    /// `GET /alpha/*`：Bearer Key + Accept JSON；401/403 给鉴权提示，200 携带 success=false 也视为失败
    private static func commandCodeGet(key: String, path: String, session: URLSession) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: commandCodeBase + path)!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw QueryError.remote("CommandCode: 鉴权失败 (HTTP \(status))，请检查 API Key（commandcode.ai › Studio › API Keys）")
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw QueryError.remote("CommandCode: 响应解析失败 (HTTP \(status)) \(path)")
        }
        if status != 200 {
            throw QueryError.remote("CommandCode: HTTP \(status) \(path.split(separator: "?").first ?? "")")
        }
        if JSONUtil.bool(json, "success") == false,
           let error = json["error"] as? [String: Any] {
            throw QueryError.remote("CommandCode: \(JSONUtil.string(error, "message", "code") ?? "未知错误")")
        }
        return json
    }

    private static func commandCodeOrgID(_ who: [String: Any]) -> String {
        if let org = who["org"] as? [String: Any], let id = JSONUtil.string(org, "id") { return id }
        if let data = who["data"] as? [String: Any],
           let org = data["org"] as? [String: Any], let id = JSONUtil.string(org, "id") { return id }
        return ""
    }

    /// credits + 已花费 → 窗口列表；`limited=false`（纯按量套餐）不解析滚动窗口
    private static func parseCommandCode(credits root: [String: Any], spent: Double,
                                         planID: String, periodEnd: Date?) -> ProviderUsage {
        let credits = (root["credits"] as? [String: Any]) ?? root
        let pool = max(0, JSONUtil.double(credits, "monthlyCredits") ?? 0)
            + max(0, JSONUtil.double(credits, "purchasedCredits") ?? 0)
            + max(0, JSONUtil.double(credits, "freeCredits") ?? 0)

        let windowLimits = (root["windowLimits"] as? [String: Any])
            ?? (credits["windowLimits"] as? [String: Any]) ?? [:]
        let paygOnly = JSONUtil.bool(windowLimits, "limited") == false

        var windows: [QuotaWindow] = []
        if !paygOnly {
            for (key, label) in [("fiveHour", QuotaWindow.fiveHour), ("weekly", QuotaWindow.weekly)] {
                guard let win = windowLimits[key] as? [String: Any] else { continue }
                let cap = JSONUtil.double(win, "cap") ?? 0
                guard cap > 0 else { continue }                       // 未配置的窗口跳过
                let used = JSONUtil.double(win, "used") ?? 0
                windows.append(QuotaWindow(
                    name: label,
                    percent: min(max(used / cap * 100, 0), 100),
                    used: used, total: cap, unit: "USD",
                    resetTime: JSONUtil.date(win, "resetAt")))
            }
        }
        if pool > 0 {
            // credits 是「剩余」池：套餐月度总额 = 已花 + 剩余（实测 GOAT：30.91 + 39.35 = 70.26）。
            // 因此使用率 = spent /(spent + remaining)；直接 spent/remaining 会在周期后段严重高估。
            let allotment = spent + pool
            windows.append(QuotaWindow(
                name: QuotaWindow.monthly,
                percent: min(max(spent / allotment * 100, 0), 100),
                used: spent, total: allotment, unit: "USD",
                resetTime: periodEnd,
                remainingOverride: pool))
        }
        guard !windows.isEmpty else {
            return ProviderUsage(kind: .commandCode, ok: false,
                                 errorMessage: "credits 池为 0 且无滚动窗口（套餐可能未生效，检查 Studio › Billing）")
        }
        let plan = commandCodePlanLabel(planID)
        return ProviderUsage(kind: .commandCode, ok: true,
                             windows: windows, subtitle: plan,
                             balance: pool > 0 ? pool : nil,
                             currency: pool > 0 ? "USD" : nil)
    }

    private static func commandCodePlanLabel(_ planID: String) -> String {
        switch planID.lowercased() {
        case "": return ""
        case "go": return "Go"
        case "individual-goat", "goat": return "GOAT"
        case "pro": return "Pro"
        case "max10", "max_10x", "max-10x": return "Max 10x"
        case "max20", "max_20x", "max-20x": return "Max 20x"
        case "provider": return "Provider"
        case let other: return other
        }
    }
}
