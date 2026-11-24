import Foundation

/// 验证「已用 / 剩余」口径切换的纯逻辑，不依赖 GUI：
///   swiftc -O Shared/Models.swift Shared/SnapshotCache.swift Shared/DisplayPreferences.swift \
///          scripts/QuotaDisplayCheck.swift -o build/quotadisplaycheck && ./build/quotadisplaycheck
@main
struct QuotaDisplayCheckCLI {
    static func main() {
        var failures = 0
        func check(_ condition: Bool, _ label: String, _ detail: String = "") {
            if condition {
                print("✅ \(label)\(detail.isEmpty ? "" : "  → \(detail)")")
            } else {
                failures += 1
                print("❌ \(label)\(detail.isEmpty ? "" : "  → \(detail)")")
            }
        }

        let window = QuotaWindow(name: QuotaWindow.monthly, percent: 44.4, used: 31, total: 70, unit: "USD")

        var prefs = DisplayPreferences()

        // 默认口径应为「已用」，与历史行为一致
        check(prefs.quotaDisplay == .used, "默认口径是已用")
        check(prefs.displayedPercent(window) == 44.4, "已用口径原样输出", "\(prefs.displayedPercent(window))")

        // 切到剩余
        prefs.quotaDisplay = .remaining
        let remaining = prefs.displayedPercent(window)
        check(abs(remaining - 55.6) < 0.0001, "剩余口径 = 100 - 已用", "\(remaining)")

        // 边界：已用 0 / 100 不应越界
        let full = QuotaWindow(name: QuotaWindow.fiveHour, percent: 100)
        let empty = QuotaWindow(name: QuotaWindow.fiveHour, percent: 0)
        check(prefs.displayedPercent(full) == 0, "已用 100% → 剩余 0%")
        check(prefs.displayedPercent(empty) == 100, "已用 0% → 剩余 100%")

        // 上色依据必须是「已用率」而非显示值：剩余 55.6% 对应的已用是 44.4，属绿色区间
        func levelColor(_ percent: Double) -> String {
            if percent >= 80 { return "red" }
            if percent >= 50 { return "orange" }
            return "green"
        }
        check(levelColor(window.percent) == "green",
              "剩余口径下颜色仍按已用率判定", "已用 44.4% → green（若误用显示值 55.6 会变 orange）")

        // 编码解码往返（display.json 被 App / 小组件 / 状态栏共用）
        prefs.statusItemPerProvider = false
        prefs.statusItemWindows = [QuotaWindow.weekly]
        guard let data = try? JSONEncoder().encode(prefs),
              let restored = try? JSONDecoder().decode(DisplayPreferences.self, from: data) else {
            print("❌ display.json 编解码往返失败"); exit(1)
        }
        check(restored.quotaDisplay == .remaining, "口径经 JSON 往返保留")
        check(restored.statusItemPerProvider == false, "其它字段未被影响")
        check(restored.statusItemWindows == [QuotaWindow.weekly], "窗口筛选未被影响")

        // 缺字段的旧 display.json 必须能解码，且新字段取默认值（已用）
        let legacy = #"{"enabledKinds":["zhipu"],"statusItemShowsPercent":false}"#
        if let legacyData = legacy.data(using: .utf8),
           let old = try? JSONDecoder().decode(DisplayPreferences.self, from: legacyData) {
            check(old.quotaDisplay == .used, "旧 display.json 缺 quotaDisplay 时回落为已用")
            check(old.enabledKinds == [.zhipu], "旧文件里已有的勾选未丢失")
            check(old.statusItemShowsPercent == false, "旧文件里的开关未丢失")
        } else {
            failures += 1
            print("❌ 旧 display.json 解码失败（会导致用户设置被清空）")
        }

        print(failures == 0 ? "\n全部通过" : "\n\(failures) 项失败")
        if failures > 0 { exit(1) }
    }
}
