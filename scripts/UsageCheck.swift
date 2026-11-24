import Foundation

/// 终端自检：swiftc Shared/{Models,ProvidersStore,QueryService,SnapshotCache}.swift scripts/UsageCheck.swift -o build/usagecheck && ./build/usagecheck
@main
struct UsageCheckCLI {
    static func main() async {
        print("== QuotaBar 查询自检 ==")
        print("cc-switch 数据库: \(ProvidersStore.dbURL.path)")
        let credentials = ProvidersStore.loadCredentials()
        guard !credentials.isEmpty else {
            print("❌ 未识别到任何已启用用量查询的 provider")
            exit(1)
        }
        for credential in credentials {
            print("识别 → \(credential.kind.displayName)（来源 provider：\(credential.sourceName)，凭据 \(credential.keyDescription)）")
        }
        print("查询中…")
        let results = await QueryService.fetchAll(credentials)
        SnapshotCache.save(results)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(results), let text = String(data: data, encoding: .utf8) {
            print(text)
        }
        var failed = 0
        for result in results {
            if result.ok {
                print("✅ \(result.kind.displayName)")
            } else {
                failed += 1
                print("❌ \(result.kind.displayName): \(result.errorMessage ?? "")")
            }
        }
        if failed > 0 { exit(2) }
    }
}
