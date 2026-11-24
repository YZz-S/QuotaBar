import Foundation

/// 验证 App Group 改名后的旧容器迁移逻辑，不依赖 GUI：
///   swiftc -O Shared/Models.swift Shared/SnapshotCache.swift scripts/AppGroupMigrationCheck.swift \
///          -o build/migrationcheck && ./build/migrationcheck
///
/// 用临时目录模拟"旧容器/新容器"，覆盖：正常迁移、目标已存在不覆盖、旧容器缺失、幂等。
@main
struct AppGroupMigrationCheckCLI {
    static var failures = 0

    static func check(_ ok: Bool, _ label: String, _ detail: String = "") {
        if ok { print("✅ \(label)\(detail.isEmpty ? "" : "  → \(detail)")") }
        else { failures += 1; print("❌ \(label)\(detail.isEmpty ? "" : "  → \(detail)")") }
    }

    /// 把 AppGroup.migrateFromLegacyGroupIfNeeded 的核心算法抽出来，跑在临时目录上
    static func migrate(legacy: URL, destination: URL) -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: legacy, includingPropertiesForKeys: nil) else { return [] }
        var copied: [String] = []
        for source in files {
            let target = destination.appendingPathComponent(source.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: target.path) else { continue }
            guard (try? FileManager.default.copyItem(at: source, to: target)) != nil else { continue }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            copied.append(source.lastPathComponent)
        }
        return copied
    }

    static func main() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-migrate-\(UUID().uuidString)", isDirectory: true)
        let legacy = root.appendingPathComponent("legacy", isDirectory: true)
        let dest = root.appendingPathComponent("dest", isDirectory: true)
        try? FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // 旧容器里的三类数据
        try? Data("[\"manual-key\"]".utf8).write(to: legacy.appendingPathComponent("manual-credentials.json"))
        try? Data("{\"quotaDisplay\":\"remaining\"}".utf8).write(to: legacy.appendingPathComponent("display.json"))
        try? Data("{\"enabled\":true}".utf8).write(to: legacy.appendingPathComponent("alerts.json"))

        // 1) 首次迁移：三个文件都该过来
        let first = migrate(legacy: legacy, destination: dest)
        check(first.count == 3, "首次迁移拷贝全部 3 个文件", first.sorted().joined(separator: ", "))
        check(FileManager.default.fileExists(atPath: dest.appendingPathComponent("manual-credentials.json").path),
              "手动凭据已到新容器")
        check(FileManager.default.fileExists(atPath: dest.appendingPathComponent("display.json").path),
              "显示偏好已到新容器")
        check(FileManager.default.fileExists(atPath: dest.appendingPathComponent("alerts.json").path),
              "警戒配置已到新容器")

        // 2) 权限保持 0600
        let attrs = try? FileManager.default.attributesOfItem(
            atPath: dest.appendingPathComponent("manual-credentials.json").path)
        let perms = (attrs?[.posixPermissions] as? NSNumber)?.intValue ?? 0
        check(perms == 0o600, "凭据文件权限为 0600", String(perms, radix: 8))

        // 3) 幂等：再跑一次不应重复拷贝/报错
        let second = migrate(legacy: legacy, destination: dest)
        check(second.isEmpty, "重复执行不重复拷贝", "第二次拷贝 \(second.count) 个")

        // 4) 目标已有更新的值 → 不能被旧数据覆盖
        let newer = Data("{\"quotaDisplay\":\"used\"}".utf8)
        try? newer.write(to: dest.appendingPathComponent("display.json"))
        _ = migrate(legacy: legacy, destination: dest)
        let afterRetry = try? Data(contentsOf: dest.appendingPathComponent("display.json"))
        check(afterRetry == newer, "新版已改过的值不会被旧数据覆盖")

        // 5) 旧容器不存在（全新安装）：不应崩，返回空
        let missing = root.appendingPathComponent("nope", isDirectory: true)
        let none = migrate(legacy: missing, destination: dest)
        check(none.isEmpty, "旧容器缺失时安全返回空")

        // 6) 常量一致性：新组名与旧组名都必须是预期值
        check(AppGroup.identifier == "D35P9V7J8X.group.QuotaBar", "新 App Group 标识正确", AppGroup.identifier)
        check(AppGroup.legacyIdentifier == "D35P9V7J8X.group.ApiUsageShow", "旧 App Group 标识保留", AppGroup.legacyIdentifier)

        print(failures == 0 ? "\n全部通过" : "\n\(failures) 项失败")
        if failures > 0 { exit(1) }
    }
}
