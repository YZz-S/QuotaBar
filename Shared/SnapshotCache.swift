import Foundation

/// App 与 widget 扩展共享的 App Group 容器。widget 已沙箱化（macOS 插件注册的硬性要求），
/// 只能通过该容器与未沙箱的 App 交换凭据与快照。
enum AppGroup {
    static let identifier = "D35P9V7J8X.group.ApiUsageShow"

    /// 容器内数据目录（不存在时创建）。App 未沙箱且带 App Group entitlement，
    /// 与沙箱化的 widget 解析到同一个 ~/Library/Group Containers/<id>/ 路径。
    static var dataDirectory: URL {
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Group Containers/\(identifier)", isDirectory: true)
        let directory = container.appendingPathComponent("Library/Application Support/ApiUsageShow", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
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
