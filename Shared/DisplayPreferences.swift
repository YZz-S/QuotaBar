import Foundation

/// 额度显示口径：已用 or 剩余
enum QuotaDisplay: String, Codable, CaseIterable {
    case used
    case remaining

    var label: String {
        switch self {
        case .used: return "已用"
        case .remaining: return "剩余"
        }
    }
}

/// 「显示哪些供应商」的统一偏好（App Group 容器，App / 小组件 / 状态栏共用）。
/// 未设置（或空集合）视为「全部显示」，这样老用户升级后行为不变。
struct DisplayPreferences: Codable {
    /// 要显示的供应商；空 = 全部
    var enabledKinds: [ProviderKind] = []
    /// 是否检查（查询 + 警戒）未选中的供应商。false 时连请求都不发，省流量也避免把没订阅的渠道刷成错误
    var queryUnselected: Bool = false
    /// 状态栏显示的指标：true 显示用量数字，false 只显示图标
    var statusItemShowsPercent: Bool = true
    /// 状态栏优先显示的供应商；nil = 自动（取使用率最高的）
    var statusItemFocus: ProviderKind? = nil
    /// 状态栏展示哪些窗口：5小时 / 周 / 月；空 = 全部窗口
    var statusItemWindows: [String] = []
    /// true = 每家供应商各占一个状态栏项（能同时看到 DeepSeek 余额等）；false = 合并为一个
    var statusItemPerProvider: Bool = true
    /// 菜单栏/图标口径：已用 or 剩余
    var quotaDisplay: QuotaDisplay = .used

    init() {}

    /// 新增字段时有旧的 display.json 存在，逐字段兜底，避免用户原有勾选被清空
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabledKinds = (try? c.decode([ProviderKind].self, forKey: .enabledKinds)) ?? []
        queryUnselected = (try? c.decode(Bool.self, forKey: .queryUnselected)) ?? false
        statusItemShowsPercent = (try? c.decode(Bool.self, forKey: .statusItemShowsPercent)) ?? true
        statusItemFocus = try? c.decodeIfPresent(ProviderKind.self, forKey: .statusItemFocus)
        statusItemWindows = (try? c.decode([String].self, forKey: .statusItemWindows)) ?? []
        statusItemPerProvider = (try? c.decode(Bool.self, forKey: .statusItemPerProvider)) ?? true
        quotaDisplay = (try? c.decode(QuotaDisplay.self, forKey: .quotaDisplay)) ?? .used
    }

    /// 需要参与查询/展示的供应商（按展示顺序）
    var activeKinds: [ProviderKind] {
        let base: [ProviderKind] = enabledKinds.isEmpty
            ? ProviderKind.displayOrder
            : ProviderKind.displayOrder.filter { enabledKinds.contains($0) }
        return base.isEmpty ? [] : base
    }

    func isEnabled(_ kind: ProviderKind) -> Bool {
        enabledKinds.isEmpty || enabledKinds.contains(kind)
    }

    /// 状态栏要显示的窗口（按 5h → 周 → 月 排序）；空集合 = 全部
    func statusWindows(of usage: ProviderUsage) -> [QuotaWindow] {
        let ordered = usage.windowsInDisplayOrder
        guard !statusItemWindows.isEmpty else { return ordered }
        return ordered.filter { statusItemWindows.contains($0.name) }
    }

    mutating func setStatusWindow(_ name: String, _ on: Bool) {
        // 「全部」（空数组）状态下取消某一项，必须先把全集物化，否则删不动、仍旧等于全部
        let all = [QuotaWindow.fiveHour, QuotaWindow.weekly, QuotaWindow.monthly, QuotaWindow.credits]
        var current = statusItemWindows.isEmpty ? all : statusItemWindows
        if on {
            if !current.contains(name) { current.append(name) }
        } else {
            current.removeAll { $0 == name }
        }
        // 三项全选等价于「全部」，存空集合语义更清楚
        statusItemWindows = current.count >= all.count ? [] : all.filter { current.contains($0) }
    }

    func isStatusWindowEnabled(_ name: String) -> Bool {
        statusItemWindows.isEmpty || statusItemWindows.contains(name)
    }

    /// 按当前口径取窗口要显示的百分比：已用原样，剩余取 100 - 已用
    func displayedPercent(_ window: QuotaWindow) -> Double {
        switch quotaDisplay {
        case .used: return window.percent
        case .remaining: return max(0, 100 - window.percent)
        }
    }

    var quotaDisplayLabel: String { quotaDisplay.label }

    var isAllEnabled: Bool { enabledKinds.isEmpty }

    mutating func setEnabled(_ kind: ProviderKind, _ on: Bool) {
        // 从「全部」（空数组）切换到显式子集时，必须先把全集物化；否则取消勾选删不到任何东西
        var current = enabledKinds.isEmpty ? ProviderKind.displayOrder : enabledKinds
        if on {
            if !current.contains(kind) { current.append(kind) }
        } else {
            current.removeAll { $0 == kind }
        }
        enabledKinds = ProviderKind.displayOrder.filter { current.contains($0) }
        // 全选等价于「全部」，回落为空集合
        if enabledKinds.count >= ProviderKind.displayOrder.count { enabledKinds = [] }
    }

    /// 按偏好过滤查询结果，并保持展示顺序
    func filter(_ usages: [ProviderUsage]) -> [ProviderUsage] {
        let order = activeKinds
        let kept = usages.filter { order.contains($0.kind) }
        return order.compactMap { kind in kept.first { $0.kind == kind } }
    }

    func shouldQuery(_ kind: ProviderKind) -> Bool {
        isEnabled(kind) || queryUnselected
    }
}

enum DisplayStore {
    static var fileURL: URL { AppGroup.dataDirectory.appendingPathComponent("display.json") }

    private static let lock = NSLock()

    static func load() -> DisplayPreferences {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL),
              let prefs = try? JSONDecoder().decode(DisplayPreferences.self, from: data) else {
            return DisplayPreferences()
        }
        return prefs
    }

    @discardableResult
    static func save(_ prefs: DisplayPreferences) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(prefs) else { return false }
        do {
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            // 不能静默吞掉：写入失败时界面会表现成「勾选框点不动」，
            // 排查必须能看到真实原因（常见于 App Group 权限不到位）
            NSLog("[QuotaBar] display.json 写入失败: %@ -> %@", fileURL.path, String(describing: error))
            return false
        }
    }
}
