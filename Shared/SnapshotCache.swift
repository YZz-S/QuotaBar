import Foundation

/// App 与 widget 扩展共享的 App Group 容器。widget 已沙箱化（macOS 插件注册的硬性要求），
/// 只能通过该容器与未沙箱的 App 交换凭据与快照。
enum AppGroup {
    static let identifier = "D35P9V7J8X.group.QuotaBar"

    /// 改名前的容器。App Group 一换，旧容器里的手动 Key、显示偏好、警戒配置就都读不到了，
    /// 所以首次启动时把它们搬过来（见 migrateFromLegacyGroupIfNeeded）。
    static let legacyIdentifier = "D35P9V7J8X.group.ApiUsageShow"
    private static let legacyFolderName = "ApiUsageShow"
    private static let legacyMigrationFlag = "quotaBar.legacyContainerMigrated"

    /// 容器内数据目录（不存在时创建）。App 未沙箱且带 App Group entitlement，
    /// 与沙箱化的 widget 解析到同一个 ~/Library/Group Containers/<id>/ 路径。
    static var dataDirectory: URL {
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Group Containers/\(identifier)", isDirectory: true)
        let directory = container.appendingPathComponent("Library/Application Support/QuotaBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 一次性把旧容器的数据搬进新容器。只在 App 侧调用。
    ///
    /// 注意：必须用 containerURL(forSecurityApplicationGroupIdentifier:) 拿旧容器，
    /// 不能拼 ~/Library/Group Containers/<id> —— 没有对应 entitlement 时那条路径会被 TCC 拒绝，
    /// 迁移会静默失败。App 的 entitlements 因此临时同时声明新旧两个组。
    static func migrateFromLegacyGroupIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: legacyMigrationFlag) else { return }

        guard let legacyRoot = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: legacyIdentifier) else {
            // 拿不到旧组（已移除该 entitlement 或全新安装）→ 没有可迁移的东西
            defaults.set(true, forKey: legacyMigrationFlag)
            return
        }
        let legacyDirectory = legacyRoot
            .appendingPathComponent("Library/Application Support/\(legacyFolderName)", isDirectory: true)

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: legacyDirectory, includingPropertiesForKeys: nil) else {
            defaults.set(true, forKey: legacyMigrationFlag)
            return
        }

        let destination = dataDirectory
        var copied: [String] = []
        for source in files {
            let target = destination.appendingPathComponent(source.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: target.path) else { continue }
            guard (try? FileManager.default.copyItem(at: source, to: target)) != nil else { continue }
            copied.append(source.lastPathComponent)
            // 凭据文件保持 0600，别因为复制放宽了权限
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: target.path)
        }

        if !copied.isEmpty {
            NSLog("QuotaBar: migrated %d file(s) from legacy App Group: %@",
                  copied.count, copied.joined(separator: ", "))
        }
        defaults.set(true, forKey: legacyMigrationFlag)
    }
}

/// 最近一次成功查询的快照（App 与 widget 扩展共用同一文件，位于 App Group 容器）
enum SnapshotCache {
    static var fileURL: URL { AppGroup.dataDirectory.appendingPathComponent("snapshot.json") }

    static func save(_ usages: [ProviderUsage]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(usages) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func load() -> [ProviderUsage]? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([ProviderUsage].self, from: data)
    }
}
