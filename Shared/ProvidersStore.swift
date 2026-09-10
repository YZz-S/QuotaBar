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

    static func loadCredentials() -> [ProviderCredentials] {
        let fromDatabase = loadFromDatabase()
        return fromDatabase.isEmpty ? loadExported() : fromDatabase
    }

    /// App 调用：把识别到的凭据写入 App Group 容器供 widget 使用（仅本用户可读）
    static func exportCredentials(_ credentials: [ProviderCredentials]) {
        guard !credentials.isEmpty, let data = try? JSONEncoder().encode(credentials) else { return }
        try? data.write(to: exportedURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: exportedURL.path)
    }

    static func loadExported() -> [ProviderCredentials] {
        guard let data = try? Data(contentsOf: exportedURL) else { return [] }
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
