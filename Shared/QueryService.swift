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
        let order: [ProviderKind] = ProviderKind.displayOrder
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
            case .kimi: return try await fetchKimi(credential, timeout: timeout)
            case .miniMax: return try await fetchMiniMax(credential, timeout: timeout)
            case .zenMux: return try await fetchZenMux(credential, timeout: timeout)
            case .ollamaCloud: return try await fetchOllamaCloud(credential, timeout: timeout)
            case .mimoTokenPlan: return try await fetchMimoTokenPlan(credential, timeout: timeout)
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
        // 套餐池已花（totalMonthlyCredits）；缺失则传 nil，由解析器按剩余占比摊销
        return parseCommandCode(credits: creditsJSON, spent: totalCost,
                                planID: planID, periodEnd: periodEnd,
                                monthlySpent: JSONUtil.double(summaryJSON, "totalMonthlyCredits"))
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

    /// credits + 已花费 → 窗口列表；`limited=false`（纯按量套餐）不解析滚动窗口。
    /// 套餐额度（monthly）与付费额度（purchased + free）分开统计：池子不同，混算会互相稀释。
    /// - Parameter monthlySpent: summary 的 totalMonthlyCredits（套餐池已花）；nil 时按剩余占比摊销
    static func parseCommandCode(credits root: [String: Any], spent: Double,
                                 planID: String, periodEnd: Date?,
                                 monthlySpent: Double? = nil) -> ProviderUsage {
        let credits = (root["credits"] as? [String: Any]) ?? root
        // monthlyCredits = 订阅每月发放，周期结束作废 → 「套餐」
        // purchasedCredits / freeCredits = 额外充值、赠送，不随周期清零 → 「付费」
        let monthlyRemain = max(0, JSONUtil.double(credits, "monthlyCredits") ?? 0)
        let paidRemain = max(0, JSONUtil.double(credits, "purchasedCredits") ?? 0)
            + max(0, JSONUtil.double(credits, "freeCredits") ?? 0)
        let pool = monthlyRemain + paidRemain
        // 已花分池：summary 的 total{Monthly,Purchased,Free}Credits；缺失时按剩余占比摊销
        let monthSpent: Double
        if let monthlySpent {
            monthSpent = monthlySpent
        } else {
            let totalRemain = pool > 0 ? pool : 1
            monthSpent = spent * (monthlyRemain / totalRemain)
        }

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
        if monthlyRemain > 0 || monthSpent > 0 {
            // 套餐 monthly 池是「剩余」：套餐总额 = 已花 + 剩余（实测 GOAT：37.88 + 32.39 = 70.27）。
            // 因此使用率 = spent /(spent + remaining)；直接 spent/remaining 会在周期后段严重高估。
            let allotment = monthSpent + monthlyRemain
            windows.append(QuotaWindow(
                name: QuotaWindow.monthly,
                percent: min(max(monthSpent / allotment * 100, 0), 100),
                used: monthSpent, total: allotment, unit: "USD",
                resetTime: periodEnd,
                remainingOverride: monthlyRemain))
        }
        // 付费额度单独记在 paidBalance（不随套餐周期重置）；并入「月」会把套餐使用率摊薄，
        // 也不放进 windows —— QuotaWindow.percent 非可选，塞个 0 会让菜单栏显示成「付费 0%」。
        guard !windows.isEmpty || paidRemain > 0 else {
            return ProviderUsage(kind: .commandCode, ok: false,
                                 errorMessage: "credits 池为 0 且无滚动窗口（套餐可能未生效，检查 Studio › Billing）")
        }
        let plan = commandCodePlanLabel(planID)
        return ProviderUsage(kind: .commandCode, ok: true,
                             windows: windows, subtitle: plan,
                             balance: monthlyRemain > 0 ? monthlyRemain : nil,
                             paidBalance: paidRemain > 0 ? paidRemain : nil,
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

// MARK: - 其余 Coding Plan 供应商（Kimi / MiniMax / ZenMux / Ollama Cloud / 小米 MiMo）
//
// 端点、鉴权头、字段语义逐条对齐 cc-switch `src-tauri/src/services/coding_plan.rs`
// （已实测：各家百分比是「剩余」还是「已用」不同，别互相套用）。

extension QueryService {
    /// 百分比可能给 0-100 也可能给 0-1；全组 ≤1 且有非零值时按分数放大
    fileprivate static func normalizePercent(_ value: Double, allFraction: Bool) -> Double {
        let scaled = allFraction ? value * 100 : value
        return min(max(scaled, 0), 100)
    }

    // MARK: Kimi For Coding

    /// 解析 `GET /coding/v1/usages`：`limits[].detail` = 5 小时窗口、`usage` = 周窗口。
    /// 两处都给「剩余」（limit / remaining 都是次数），所以已用 = limit - remaining。
    static func parseKimiUsage(_ json: [String: Any]) -> [QuotaWindow] {
        func window(_ node: Any?) -> (used: Double, total: Double, reset: Date?)? {
            guard let node = node as? [String: Any] else { return nil }
            let limit = JSONUtil.double(node, "limit") ?? 0
            let remaining = JSONUtil.double(node, "remaining") ?? 0
            guard limit > 0 else { return nil }
            return (max(limit - remaining, 0), limit, JSONUtil.date(node, "resetTime", "resetAt"))
        }

        var windows: [QuotaWindow] = []
        // 可能有多条 limits，取第一条有可用 detail 的作为 5 小时窗口
        if let limits = json["limits"] as? [[String: Any]] {
            for limit in limits {
                if let parsed = window(limit["detail"]) {
                    windows.append(QuotaWindow(name: QuotaWindow.fiveHour,
                                               percent: parsed.used / parsed.total * 100,
                                               used: parsed.used, total: parsed.total,
                                               unit: "次", resetTime: parsed.reset))
                    break
                }
            }
        }
        if let parsed = window(json["usage"]) {
            windows.append(QuotaWindow(name: QuotaWindow.weekly,
                                       percent: parsed.used / parsed.total * 100,
                                       used: parsed.used, total: parsed.total,
                                       unit: "次", resetTime: parsed.reset))
        }
        return windows
    }

    private static func fetchKimi(_ credential: ProviderCredentials, timeout: TimeInterval) async throws -> ProviderUsage {
        guard let key = credential.apiKey else { throw QueryError.missingCredentials("Kimi API Key 未配置") }
        let base = credential.baseUrl ?? "https://api.kimi.com/coding/v1"
        guard let url = URL(string: base.trimmingTrailingSlashes() + "/usages") else {
            throw QueryError.remote("Kimi: baseUrl 无效")
        }
        let json = try await getJSON(url,
            headers: ["Authorization": "Bearer \(key)", "Accept": "application/json"],
            label: "Kimi", timeout: timeout)
        if let error = json["error"] as? [String: Any],
           let message = JSONUtil.string(error, "message") {
            throw QueryError.remote("Kimi: \(message)")
        }
        let windows = parseKimiUsage(json)
        guard !windows.isEmpty else { throw QueryError.remote("Kimi: 无用量数据（可能是 Key 无 Coding Plan）") }
        return ProviderUsage(kind: .kimi, ok: true, windows: windows, subtitle: "Coding Plan")
    }

    // MARK: MiniMax Coding Plan

    /// 解析 `GET /v1/api/openplatform/coding_plan/remains`。
    /// 返回**剩余**百分比（`current_*_remaining_percent`），已用 = 100 - 剩余。
    /// `model_remains[]` 只取 `model_name == "general"`；周桶靠 `current_weekly_status`
    /// 区分（1 计时 / 2 已耗尽照常展示 / 3 无周限额 → 跳过）。
    static func parseMiniMaxTiers(_ json: [String: Any]) -> [QuotaWindow] {
        guard let items = json["model_remains"] as? [[String: Any]],
              let general = items.first(where: { JSONUtil.string($0, "model_name") == "general" }) else {
            return []
        }
        var windows: [QuotaWindow] = []
        if let remain = JSONUtil.double(general, "current_interval_remaining_percent") {
            windows.append(QuotaWindow(
                name: QuotaWindow.fiveHour,
                percent: min(max(100 - remain, 0), 100),
                resetTime: JSONUtil.date(general, "end_time")))
        }
        let weeklyStatus = JSONUtil.int(general, "current_weekly_status")
        if weeklyStatus == 1 || weeklyStatus == 2,
           let remain = JSONUtil.double(general, "current_weekly_remaining_percent") {
            windows.append(QuotaWindow(
                name: QuotaWindow.weekly,
                percent: min(max(100 - remain, 0), 100),
                resetTime: JSONUtil.date(general, "weekly_end_time")))
        }
        return windows
    }

    private static func fetchMiniMax(_ credential: ProviderCredentials, timeout: TimeInterval) async throws -> ProviderUsage {
        guard let key = credential.apiKey else { throw QueryError.missingCredentials("MiniMax API Key 未配置") }
        let host = (credential.baseUrl?.lowercased().contains("minimax.io") ?? false)
            ? "api.minimax.io" : "api.minimaxi.com"
        guard let url = URL(string: "https://\(host)/v1/api/openplatform/coding_plan/remains") else {
            throw QueryError.remote("MiniMax: 端点无效")
        }
        let json = try await getJSON(url,
            headers: ["Authorization": "Bearer \(key)", "Content-Type": "application/json"],
            label: "MiniMax", timeout: timeout)
        if let base = json["base_resp"] as? [String: Any] {
            let code = JSONUtil.int(base, "status_code") ?? -1
            if code != 0 {
                let message = JSONUtil.string(base, "status_msg") ?? "未知错误"
                throw QueryError.remote("MiniMax: \(message)（code \(code)）")
            }
        }
        let windows = parseMiniMaxTiers(json)
        guard !windows.isEmpty else {
            throw QueryError.remote("MiniMax: 响应中没有 general 模型额度")
        }
        return ProviderUsage(kind: .miniMax, ok: true, windows: windows, subtitle: "Coding Plan")
    }

    // MARK: ZenMux

    /// 解析 ZenMux 额度响应：`data.quota_5_hour` / `quota_7_day` 的 `usage_percentage`
    /// 是 0-1 分数（不是 0-100），按「全组 ≤1 且有非零值」判定后再放大。
    static func parseZenMuxTiers(_ data: [String: Any]) -> [QuotaWindow] {
        let spec: [(key: String, name: String)] = [
            ("quota_5_hour", QuotaWindow.fiveHour),
            ("quota_7_day", QuotaWindow.weekly),
        ]
        var raws: [(String, [String: Any], Double)] = []
        for item in spec {
            guard let node = data[item.key] as? [String: Any],
                  let pct = JSONUtil.double(node, "usage_percentage") else { continue }
            raws.append((item.name, node, pct))
        }
        guard !raws.isEmpty else { return [] }
        let allFraction = raws.allSatisfy { $0.2 >= 0 && $0.2 <= 1 } && raws.contains { $0.2 > 0 }

        return raws.map { name, node, raw -> QuotaWindow in
            let maxUSD = JSONUtil.double(node, "max_value_usd")
            return QuotaWindow(
                name: name,
                percent: normalizePercent(raw, allFraction: allFraction),
                used: JSONUtil.double(node, "used_value_usd"),
                total: maxUSD,
                unit: maxUSD == nil ? nil : "USD",
                resetTime: JSONUtil.date(node, "resets_at", "resetAt"))
        }
    }

    private static func fetchZenMux(_ credential: ProviderCredentials, timeout: TimeInterval) async throws -> ProviderUsage {
        guard let key = credential.apiKey else { throw QueryError.missingCredentials("ZenMux API Key 未配置") }
        guard let base = credential.baseUrl, let url = URL(string: base) else {
            throw QueryError.remote("ZenMux: 未获取到 baseUrl（额度端点就是 provider 的 base_url）")
        }
        let json = try await getJSON(url,
            headers: ["Authorization": "Bearer \(key)", "Accept": "application/json"],
            label: "ZenMux", timeout: timeout)
        if JSONUtil.bool(json, "success") != true {
            let message = JSONUtil.string(json, "message") ?? "未知错误"
            throw QueryError.remote("ZenMux: \(message)")
        }
        guard let data = json["data"] as? [String: Any] else {
            throw QueryError.remote("ZenMux: 响应缺少 data 字段")
        }
        let windows = parseZenMuxTiers(data)
        guard !windows.isEmpty else {
            throw QueryError.remote("ZenMux: 响应中没有 5 小时 / 7 天窗口")
        }
        let tier = ((data["plan"] as? [String: Any]).flatMap { JSONUtil.string($0, "tier") })
            ?? JSONUtil.string(data, "plan_name") ?? ""
        return ProviderUsage(kind: .zenMux, ok: true, windows: windows,
                             subtitle: tier.isEmpty ? "Token Plan" : tier)
    }

    // MARK: Ollama Cloud

    /// 解析 `GET /api/balance`：
    /// - 新套餐：`included.allowance_usd` 本期总额 + `balance_usd` 剩余 → 月度档，已用 = 差额
    /// - 老套餐：`included.session/weekly.remaining_percent` → 已用 = 100 - 剩余
    /// - `allowance_usd == 0`：按量付费账户，没有套餐额度（返回空，由调用方给出提示）
    static func parseOllamaCloudTiers(_ json: [String: Any]) -> [QuotaWindow] {
        guard let included = json["included"] as? [String: Any] else { return [] }
        if let allowance = JSONUtil.double(included, "allowance_usd"),
           let balance = JSONUtil.double(included, "balance_usd"), allowance > 0 {
            let used = min(max(allowance - balance, 0), allowance)
            let period = (included["period"] as? [String: Any]) ?? [:]
            return [QuotaWindow(
                name: QuotaWindow.monthly,
                percent: used / allowance * 100,
                used: used, total: allowance, unit: "USD",
                resetTime: JSONUtil.date(period, "until", "to"))]
        }
        var windows: [QuotaWindow] = []
        for (key, name) in [("session", QuotaWindow.fiveHour), ("weekly", QuotaWindow.weekly)] {
            guard let node = included[key] as? [String: Any],
                  let remaining = JSONUtil.double(node, "remaining_percent") else { continue }
            windows.append(QuotaWindow(
                name: name,
                percent: min(max(100 - remaining, 0), 100),
                resetTime: JSONUtil.date(node, "resets_at", "resetAt")))
        }
        return windows
    }

    private static func fetchOllamaCloud(_ credential: ProviderCredentials, timeout: TimeInterval) async throws -> ProviderUsage {
        guard let key = credential.apiKey else { throw QueryError.missingCredentials("Ollama Cloud API Key 未配置") }
        guard let url = URL(string: "https://ollama.com/api/balance") else {
            throw QueryError.remote("Ollama Cloud: 端点无效")
        }
        let json = try await getJSON(url,
            headers: ["Authorization": "Bearer \(key)", "Accept": "application/json"],
            label: "Ollama Cloud", timeout: timeout)
        let windows = parseOllamaCloudTiers(json)
        if windows.isEmpty {
            let included = (json["included"] as? [String: Any]) ?? [:]
            let allowance = JSONUtil.double(included, "allowance_usd")
            if let allowance, allowance <= 0 {
                throw QueryError.remote("Ollama Cloud: 该账户没有套餐额度（按量付费）")
            }
            throw QueryError.remote("Ollama Cloud: 响应形态无法识别（缺 included.allowance_usd）")
        }
        return ProviderUsage(kind: .ollamaCloud, ok: true, windows: windows, subtitle: "Cloud")
    }

    // MARK: 小米 MiMo Token Plan

    /// 解析 `GET /v1/platform/token_plan`：`quota.total_credits` 是本期总额（含补偿积分），
    /// 已用优先 `used_credits`，否则 `total - remaining_credits`。
    /// 周期可月付可年付，因此落「额度」档而不是「月」。
    static func parseMimoTokenPlanTiers(_ json: [String: Any]) -> [QuotaWindow] {
        guard let quota = json["quota"] as? [String: Any],
              let total = JSONUtil.double(quota, "total_credits"),
              total.isFinite, total > 0 else { return [] }
        let used: Double
        if let value = JSONUtil.double(quota, "used_credits") {
            used = value
        } else if let remaining = JSONUtil.double(quota, "remaining_credits") {
            used = total - remaining
        } else {
            return []
        }
        let period = (json["period"] as? [String: Any]) ?? [:]
        return [QuotaWindow(
            name: QuotaWindow.credits,
            percent: min(max(used / total * 100, 0), 100),
            used: used, total: total, unit: "积分",
            resetTime: mimoPeriodTime(period["end_at"]))]
    }

    private static func fetchMimoTokenPlan(_ credential: ProviderCredentials, timeout: TimeInterval) async throws -> ProviderUsage {
        guard let key = credential.apiKey else { throw QueryError.missingCredentials("小米 MiMo Token Plan Key 未配置") }
        guard let url = URL(string: "https://token-plan-cn.xiaomimimo.com/v1/platform/token_plan") else {
            throw QueryError.remote("小米 MiMo: 端点无效")
        }
        let json = try await getJSON(url,
            headers: ["Authorization": "Bearer \(key)", "Accept": "application/json"],
            label: "小米 MiMo", timeout: timeout)

        if let error = json["error"] as? [String: Any],
           let message = JSONUtil.string(error, "message") {
            throw QueryError.remote("小米 MiMo: \(message)")
        }
        let windows = parseMimoTokenPlanTiers(json)
        guard !windows.isEmpty else {
            throw QueryError.remote("小米 MiMo: 该 Key 没有 Token Plan 额度（需 tp- 开头的 Key）")
        }
        let planCode = JSONUtil.string(json, "plan_code") ?? ""
        return ProviderUsage(kind: .mimoTokenPlan, ok: true, windows: windows,
                             subtitle: planCode.isEmpty ? "Token Plan" : planCode)
    }

    /// MiMo 的周期时间是「UTC，`YYYY-MM-DD HH:mm:ss`」，转成 Date；其他格式交回通用解析
    static func mimoPeriodTime(_ raw: Any?) -> Date? {
        if let text = raw as? String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            if let date = formatter.date(from: text.trimmingCharacters(in: .whitespaces)) {
                return date
            }
        }
        guard let raw else { return nil }
        return JSONUtil.date(["v": raw], "v")
    }

    /// 单次 GET → JSON，统一处理鉴权失败与非 200
    fileprivate static func getJSON(_ url: URL, headers: [String: String],
                                    label: String, timeout: TimeInterval) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await makeSession(timeout).data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw QueryError.remote("\(label): 响应解析失败 (HTTP \(status))")
        }
        return json
    }
}

extension String {
    /// 拼接端点时去掉尾部斜杠，避免出现 `//usages`
    fileprivate func trimmingTrailingSlashes() -> String {
        var text = self
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }
}
