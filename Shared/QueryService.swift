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
        let order: [ProviderKind] = [.volcengine, .zhipu, .deepseek]
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
}
