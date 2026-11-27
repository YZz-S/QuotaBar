import Foundation
import SQLite3

/// 读取 ~/.cc-switch/cc-switch.db，自动识别已启用用量查询的 provider 凭据。
/// 与 cc-switch 的识别规则保持一致（providers.meta.usage_script）。
/// 沙箱化的 widget 读不到该数据库，改读 App 导出到 App Group 容器的副本。
enum ProvidersStore {
    static var dbURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cc-switch/cc-switch.db")
    }

    static var exportedURL: URL { AppGroup.dataDirectory.appendingPathComponent("credentials.json") }
    /// 用户在 App 设置页手动填写的凭据，按 provider 覆盖 cc-switch 自动识别的结果
    static var manualURL: URL { AppGroup.dataDirectory.appendingPathComponent("manual-credentials.json") }

    static let manualSourceName = "手动配置"

    static func loadCredentials() -> [ProviderCredentials] {
        var merged = loadFromDatabase()
        if merged.isEmpty { merged = loadExported().filter { $0.sourceName != manualSourceName } }
        for manual in loadManual() {
            if let index = merged.firstIndex(where: { $0.kind == manual.kind }) {
                merged[index] = manual
            } else {
                merged.append(manual)
            }
        }
        let order: [ProviderKind] = ProviderKind.displayOrder
        return merged.sorted { (order.firstIndex(of: $0.kind) ?? 9) < (order.firstIndex(of: $1.kind) ?? 9) }
    }

    /// App 调用：把识别到的凭据写入 App Group 容器供 widget 使用（仅本用户可读）
    static func exportCredentials(_ credentials: [ProviderCredentials]) {
        guard !credentials.isEmpty else { return }
        writeSecure(credentials, to: exportedURL)
    }

    static func loadExported() -> [ProviderCredentials] { read(exportedURL) }

    static func loadManual() -> [ProviderCredentials] { read(manualURL) }

    static func saveManual(_ credentials: [ProviderCredentials]) {
        if credentials.isEmpty {
            try? FileManager.default.removeItem(at: manualURL)
        } else {
            writeSecure(credentials, to: manualURL)
        }
    }

    private static func writeSecure(_ credentials: [ProviderCredentials], to url: URL) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func read(_ url: URL) -> [ProviderCredentials] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([ProviderCredentials].self, from: data)) ?? []
    }

    static func loadFromDatabase() -> [ProviderCredentials] {
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return [] }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }

        var credentials: [ProviderCredentials] = []
        var statement: OpaquePointer?
        let sql = "SELECT name, settings_config, meta FROM providers ORDER BY sort_index, created_at"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            let name = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
            let settingsJSON = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "{}"
            let metaJSON = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? "{}"
            guard let credential = identify(name: name, settingsJSON: settingsJSON, metaJSON: metaJSON),
                  !credentials.contains(where: { $0.kind == credential.kind }) else { continue }
            credentials.append(credential)
        }
        return credentials
    }

    private static func identify(name: String, settingsJSON: String, metaJSON: String) -> ProviderCredentials? {
        guard let settings = (try? JSONSerialization.jsonObject(with: Data(settingsJSON.utf8))) as? [String: Any],
              let meta = (try? JSONSerialization.jsonObject(with: Data(metaJSON.utf8))) as? [String: Any] else {
            return nil
        }
        let script = (meta["usage_script"] as? [String: Any]) ?? [:]
        let enabled = JSONUtil.bool(script, "enabled") ?? false
        let env = (settings["env"] as? [String: Any]) ?? [:]
        let inferenceBaseURL = env["ANTHROPIC_BASE_URL"] as? String ?? ""
        let codingPlanProvider = script["codingPlanProvider"] as? String

        // 火山方舟：AK/SK 存在 usage_script 里（推理 key 无法查额度）
        if enabled, codingPlanProvider == "volcengine",
           let accessKey = JSONUtil.string(script, "accessKeyId"),
           let secretKey = JSONUtil.string(script, "secretAccessKey") {
            return ProviderCredentials(
                kind: .volcengine, sourceName: name,
                accessKey: accessKey, secretKey: secretKey,
                region: region(from: inferenceBaseURL))
        }

        // 智谱：apiKey（id.secret 格式），baseUrl 来自自定义脚本或默认 CN 端点
        if enabled, codingPlanProvider == "zhipu",
           let apiKey = JSONUtil.string(script, "apiKey") {
            let baseURL = JSONUtil.string(script, "baseUrl")
                ?? "https://open.bigmodel.cn/api/monitor/usage/quota/limit"
            return ProviderCredentials(kind: .zhipu, sourceName: name, apiKey: apiKey, baseUrl: baseURL)
        }

        // DeepSeek：余额模板，key 在写入 CLI 的 env 里
        if inferenceBaseURL.contains("api.deepseek.com"),
           let token = JSONUtil.string(env, "ANTHROPIC_AUTH_TOKEN", "DEEPSEEK_API_KEY"),
           enabled || script["templateType"] as? String == "balance" {
            return ProviderCredentials(kind: .deepseek, sourceName: name, bearerToken: token)
        }

        // OpenCode Go / Zen Go：baseURL 指向 opencode.ai/zen/go，key 是 sk-（key_env 或 options.apiKey）
        let openCodeBase = inferenceBaseURL + " " + (JSONUtil.string(env, "OPENCODE_GO_BASE_URL", "OPENCODE_ZEN_BASE_URL") ?? "")
            + " " + (JSONUtil.string(settings, "base_url") ?? "")
            + " " + (((settings["options"] as? [String: Any]).flatMap { JSONUtil.string($0, "baseURL") }) ?? "")
        let looksOpenCode = openCodeBase.contains("opencode.ai/zen/go") || inferenceBaseURL.contains("opencode.ai")
        if looksOpenCode, let key = openCodeKey(settings: settings, env: env) {
            return ProviderCredentials(kind: .openCodeGo, sourceName: name, apiKey: key)
        }

        // CommandCode：usage_script.codingPlanProvider == "command_code"，key 与 base_url 都在 provider 自身配置里
        if enabled, codingPlanProvider == "command_code",
           let key = JSONUtil.string(settings, "api_key", "apiKey") {
            return ProviderCredentials(kind: .commandCode, sourceName: name, apiKey: key)
        }

        // ── 其余 Coding Plan：先认显式 codingPlanProvider，再按 base_url 主机名自动识别
        //    （与 cc-switch 的 detect_provider 同口径，含路径前缀要求，不认中转站伪造域名）。
        if let plan = planProvider(explicit: codingPlanProvider, baseURL: inferenceBaseURL) {
            switch plan {
            case .kimi, .miniMax, .ollamaCloud, .mimoTokenPlan, .mimoBalance:
                if let key = planAPIKey(settings: settings, env: env) {
                    return ProviderCredentials(kind: plan, sourceName: name, apiKey: key)
                }
            case .zenMux:
                // ZenMux 的额度端点就是用户自己的 base_url，必须一起带过去
                if let key = planAPIKey(settings: settings, env: env), !inferenceBaseURL.isEmpty {
                    return ProviderCredentials(kind: .zenMux, sourceName: name,
                                              apiKey: key, baseUrl: inferenceBaseURL)
                }
            default:
                break
            }
        }

        return nil
    }

    /// 显式 `usage_script.codingPlanProvider` 优先，其次按 base_url 主机名（含路径前缀）自动识别。
    /// 只覆盖本条链路新增的四家 + ZenMux；火山 / 智谱 / CommandCode 上面已有各自更严格的规则。
    private static func planProvider(explicit: String?, baseURL: String) -> ProviderKind? {
        if let explicit {
            switch explicit.lowercased() {
            case "kimi": return .kimi
            case "minimax": return .miniMax
            case "zenmux": return .zenMux
            case "ollama_cloud": return .ollamaCloud
            case "mimo": return .mimoTokenPlan
            default: break
            }
        }
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces)),
              let host = url.host?.lowercased() else { return nil }
        let path = url.path.lowercased()
        // 主机名按标签边界匹配：api.kimi.com.example.com 这类伪造后缀不算
        func hostIs(_ candidates: [String]) -> Bool {
            candidates.contains { host == $0 || host.hasSuffix("." + $0) }
        }
        if hostIs(["api.kimi.com"]), path.hasPrefix("/coding") { return .kimi }
        if hostIs(["api.minimaxi.com", "api.minimax.cn", "api.minimax.io"]) { return .miniMax }
        if hostIs(["zenmux.ai"]) { return .zenMux }
        // ollama.com 只认云端；本地 localhost:11434 不是 http(s) 域名，天然不命中
        if hostIs(["ollama.com"]) { return .ollamaCloud }
        if hostIs(["token-plan-cn.xiaomimimo.com"]) { return .mimoTokenPlan }
        // api.xiaomimimo.com 是按量付费网关（sk- key）；token-plan-cn 才是套餐（tp- key）
        if hostIs(["api.xiaomimimo.com"]) { return .mimoBalance }
        return nil
    }

    /// 套餐查询用的 Key：先看 provider 自身，再看 env，最后按 key_env 去 dotenv 里取
    private static func planAPIKey(settings: [String: Any], env: [String: Any]) -> String? {
        if let direct = JSONUtil.string(settings, "api_key", "apiKey") { return direct }
        if let token = JSONUtil.string(env, "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY",
                                       "OPENAI_API_KEY", "OLLAMA_API_KEY") {
            return token
        }
        let options = (settings["options"] as? [String: Any]) ?? [:]
        if let literal = JSONUtil.string(options, "apiKey"), !literal.hasPrefix("{env:") { return literal }
        if let raw = JSONUtil.string(options, "apiKey"),
           raw.hasPrefix("{env:"), raw.hasSuffix("}") {
            let name = String(raw.dropFirst(5).dropLast())
            if let value = DotEnv.lookup(name) { return value }
        }
        if let keyEnv = JSONUtil.string(settings, "key_env"), let value = DotEnv.lookup(keyEnv) {
            return value
        }
        return nil
    }

    /// OpenCode Key：直接写在 provider 里 → 环境变量（含 dotenv 文件）→ options.apiKey 字面值
    private static func openCodeKey(settings: [String: Any], env: [String: Any]) -> String? {
        if let direct = JSONUtil.string(settings, "api_key", "apiKey") { return direct }
        if let keyEnv = JSONUtil.string(settings, "key_env"), let value = DotEnv.lookup(keyEnv) { return value }
        let options = (settings["options"] as? [String: Any]) ?? [:]
        if let literal = JSONUtil.string(options, "apiKey"), !literal.hasPrefix("{env:") { return literal }
        if let raw = JSONUtil.string(options, "apiKey"),
           raw.hasPrefix("{env:"), raw.hasSuffix("}") {
            let name = String(raw.dropFirst(5).dropLast())
            if let value = DotEnv.lookup(name) { return value }
        }
        // cc-switch 的两个 OpenCode provider 用的都是这套环境变量名
        for name in ["OPENCODE_GO_API_KEY", "OPENCODE_ZEN_API_KEY"] {
            if let value = DotEnv.lookup(name) { return value }
        }
        return nil
    }

    /// 从数据面地址推导火山 region：https://ark.cn-beijing.volces.com/api/coding → cn-beijing
    private static func region(from baseURL: String) -> String {
        if let range = baseURL.range(of: #"ark\.([a-z0-9-]+)\.volces\.com"#, options: .regularExpression) {
            let parts = baseURL[range].split(separator: ".")
            if parts.count >= 2 { return String(parts[1]) }
        }
        return "cn-beijing"
    }
}
