import AppKit
import SwiftUI
import WidgetKit

/// 系统状态栏（菜单栏）额度显示。
/// 菜单栏文字只能是一个短串，所以：图标 + 当前关注供应商的主窗口百分比，
/// 点开后是「每家一行 + 最后更新时间」的菜单，可在菜单里直接切换显示哪些供应商、钉住某一家。
@MainActor
final class StatusBarController: ObservableObject {
    static let shared = StatusBarController()

    /// 由 App 在启动时注入：触发一次真实查询（菜单里的「立即刷新」）
    var refreshAction: (() async -> Void)?

    private var statusItem: NSStatusItem?
    /// 多供应商模式下的额外状态栏项（每家一个）
    private var extraItems: [ProviderKind: NSStatusItem] = [:]
    private var started = false
    private var lastUsages: [ProviderUsage] = []
    private var isRefreshing = false

    private init() {}

    /// App 启动时调用一次；未开启偏好时仍创建（图标随时可点），文字保持精简
    func start() {
        guard !started else { return }
        started = true
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = nil
        item.button?.imagePosition = .imageLeading
        statusItem = item
        NotificationCenter.default.addObserver(
            forName: .statusBarShouldRefresh, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reloadFromCache() }
            }
        reloadFromCache()
    }

    /// 从快照（App Group 容器）刷新显示，不触发网络
    func reloadFromCache() {
        let prefs = DisplayStore.load()
        let cached = SnapshotCache.load() ?? []
        lastUsages = prefs.filter(cached)
        render()
    }

    /// 查完一批结果后调用：显示随偏好过滤
    func update(_ usages: [ProviderUsage]) {
        let prefs = DisplayStore.load()
        lastUsages = prefs.filter(usages)
        render()
    }

    // MARK: - 渲染

    private var focusUsage: ProviderUsage? {
        let prefs = DisplayStore.load()
        if let pinned = prefs.statusItemFocus,
           let match = lastUsages.first(where: { $0.kind == pinned }) {
            return match
        }
        // 自动：优先「使用率最高的窗口」，其次是第一家成功的
        let withWindows = lastUsages.filter { $0.ok && !$0.windows.isEmpty }
        if let peak = withWindows.max(by: { ($0.primaryWindow?.percent ?? 0) < ($1.primaryWindow?.percent ?? 0) }) {
            return peak
        }
        // 没有窗口型（只有余额型供应商）时也要能显示，否则状态栏只剩一个空图标
        return lastUsages.first { $0.ok && $0.balance != nil } ?? lastUsages.first
    }

    private func render() {
        guard let item = statusItem else { return }
        let prefs = DisplayStore.load()

        if prefs.statusItemPerProvider {
            // 每家一个项时主项只是空壳，隐藏掉避免菜单栏出现一个空气泡
            item.isVisible = false
            renderPerProviderItems(prefs)
            item.menu = buildMenu()
            return
        }

        // 合并模式：清掉多出来的项，主项恢复可见
        removeExtraItems()
        item.isVisible = true
        renderPrimaryItem(item, usage: focusUsage, prefs: prefs)
        item.menu = buildMenu()
    }

    /// 主状态栏项：图标 + 该供应商所有（或勾选的）窗口百分比，余额型显示金额
    private func renderPrimaryItem(_ item: NSStatusItem, usage: ProviderUsage?, prefs: DisplayPreferences) {
        guard let button = item.button else { return }
        guard let usage else {
            button.attributedTitle = NSAttributedString(string: "")
            button.image = Self.icon(for: nil)
            button.toolTip = "QuotaBar：暂无数据"
            return
        }
        button.image = Self.icon(for: usage.kind)
        let built = Self.title(for: usage, prefs: prefs)
        button.attributedTitle = prefs.statusItemShowsPercent
            ? Self.styledTitle(built.text, usedPercents: built.usedPercents)
            : NSAttributedString(string: "")
        button.toolTip = Self.tooltip(for: usage, prefs: prefs)
    }

    /// 多供应商模式：每个勾选的供应商各一个状态栏项（可在菜单里拖走/隐藏不需要的）
    private func renderPerProviderItems(_ prefs: DisplayPreferences) {
        var needed = Set<ProviderKind>()
        for usage in lastUsages {
            // 查询失败的供应商只留在菜单里，不在菜单栏占一个「查询失败」气泡
            guard usage.ok else { continue }
            needed.insert(usage.kind)
            let item: NSStatusItem
            if let existing = extraItems[usage.kind] {
                item = existing
            } else {
                item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                item.button?.imagePosition = .imageLeading
                extraItems[usage.kind] = item
            }
            renderPrimaryItem(item, usage: usage, prefs: prefs)
            item.menu = buildMenu()
        }
        // 该供应商不再显示时移除其状态栏项
        for (kind, item) in extraItems where !needed.contains(kind) {
            NSStatusBar.system.removeStatusItem(item)
            extraItems.removeValue(forKey: kind)
        }
    }

    private func removeExtraItems() {
        for (_, item) in extraItems { NSStatusBar.system.removeStatusItem(item) }
        extraItems.removeAll()
    }

    /// 状态栏标题：窗口型拼各窗口百分比（按当前口径），余额型给金额。
    /// 同时返回各数字对应的「已用率」，供上色用 —— 显示剩余时 84% 是好事，不能按 84 判成红色。
    private static func title(for usage: ProviderUsage, prefs: DisplayPreferences) -> (text: String, usedPercents: [Double]) {
        guard usage.ok else { return ("查询失败", []) }
        let windows = prefs.statusWindows(of: usage)
        if !windows.isEmpty {
            let parts = windows.map { "\($0.shortName) \(prefs.displayedPercent($0).percentText)" }
            return (" " + parts.joined(separator: "  "), windows.map(\.percent))
        }
        if let balance = usage.balanceText { return (" " + balance, []) }
        if let window = usage.primaryWindow {
            return (" " + prefs.displayedPercent(window).percentText, [window.percent])
        }
        return ("", [])
    }

    /// 各数字按对应的「已用率」上色，只给数字上色保持菜单栏观感
    private static func styledTitle(_ title: String, usedPercents: [Double]) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let result = NSMutableAttributedString(string: title, attributes: [
            .font: font, .foregroundColor: NSColor.labelColor,
        ])
        // 标题形态固定为「 5h 1%  周 3%  月 16%」，逐个百分比依次取对应的已用率上色
        var index = 0
        for match in title.matches(of: /(\d+(?:\.\d+)?)%/) {
            guard index < usedPercents.count else { break }
            let range = NSRange(match.range, in: title)
            result.addAttribute(.foregroundColor, value: levelColor(usedPercents[index]), range: range)
            index += 1
        }
        return result
    }

    private static func tooltip(for usage: ProviderUsage, prefs: DisplayPreferences) -> String {
        guard usage.ok else { return "\(usage.kind.displayName)：\(usage.errorMessage ?? "查询失败")" }
        var lines: [String] = []
        var head = usage.kind.displayName
        if let subtitle = usage.subtitle, !subtitle.isEmpty { head += " · \(subtitle)" }
        lines.append(head)
        if let balance = usage.balanceText { lines.append("余额 \(balance)") }
        for window in prefs.statusWindows(of: usage) {
            // 两种口径都写出来，但顺序随当前选择，读起来不费解
            let used = window.percent.percentText
            let remaining = window.remainingText
            var line = prefs.quotaDisplay == .used
                ? "\(window.name) 已用 \(used) · \(remaining)"
                : "\(window.name) \(remaining) · 已用 \(used)"
            if !window.resetCaption.isEmpty { line += " · \(window.resetCaption)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
    /// 菜单栏图标：SF Symbol 模板图（自动适配深浅色）
    private static func icon(for kind: ProviderKind?) -> NSImage? {
        let name = kind?.iconSymbol ?? "gauge.with.dots.needle.33percent"
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: kind?.displayName ?? "API 用量")?
            .withSymbolConfiguration(config) else { return nil }
        base.isTemplate = true
        return base
    }

    private static func levelColor(_ percent: Double) -> NSColor {
        if percent >= 80 { return .systemRed }
        if percent >= 50 { return .systemOrange }
        return .systemGreen
    }

    private static func summaryLine(_ usage: ProviderUsage) -> String {
        guard usage.ok else { return "\(usage.kind.displayName)：\(usage.errorMessage ?? "查询失败")" }
        let parts = usage.windowsInDisplayOrder.map { "\($0.shortName) \($0.percent.percentText)" }
        if !parts.isEmpty { return "\(usage.kind.displayName) · " + parts.joined(separator: "  ") }
        if let balance = usage.balanceText { return "\(usage.kind.displayName) · 余额 \(balance)" }
        return usage.kind.displayName
    }

    // MARK: - 菜单

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let prefs = DisplayStore.load()

        // 每家一行：名称 + 各窗口百分比/余额，点击跳控制台
        if lastUsages.isEmpty {
            menu.addItem(disabled("暂无数据，打开主窗口查询一次"))
        }
        for usage in lastUsages {
            let item = NSMenuItem(title: Self.menuTitle(usage, prefs: prefs), action: #selector(openConsole(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = usage.kind.rawValue
            item.image = smallIcon(usage.kind, level: usage.primaryWindow?.percent)
            // 悬浮在菜单项上时显示完整明细（含所有窗口与重置时间）
            item.toolTip = Self.tooltip(for: usage, prefs: prefs)
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // 显示哪些供应商
        let displayItem = NSMenuItem(title: "显示哪些供应商", action: nil, keyEquivalent: "")
        let displayMenu = NSMenu()
        for kind in ProviderKind.displayOrder {
            let entry = NSMenuItem(title: kind.displayName, action: #selector(toggleKind(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = kind.rawValue
            entry.state = prefs.isEnabled(kind) ? .on : .off
            displayMenu.addItem(entry)
        }
        displayMenu.addItem(.separator())
        let all = NSMenuItem(title: "全部显示", action: #selector(showAll), keyEquivalent: "")
        all.target = self
        all.state = prefs.isAllEnabled ? .on : .off
        displayMenu.addItem(all)
        displayItem.submenu = displayMenu
        menu.addItem(displayItem)

        // 菜单栏文字显示方式
        let textItem = NSMenuItem(title: "菜单栏显示数值", action: #selector(togglePercent), keyEquivalent: "")
        textItem.target = self
        textItem.state = prefs.statusItemShowsPercent ? .on : .off
        menu.addItem(textItem)

        // 已用 / 剩余 口径切换（顶部直接给两项，点一下即切，不用进子菜单）
        let usedItem = NSMenuItem(title: "显示已用额度", action: #selector(setDisplayUsed), keyEquivalent: "")
        usedItem.target = self
        usedItem.state = prefs.quotaDisplay == .used ? .on : .off
        menu.addItem(usedItem)
        let remainingItem = NSMenuItem(title: "显示剩余额度", action: #selector(setDisplayRemaining), keyEquivalent: "")
        remainingItem.target = self
        remainingItem.state = prefs.quotaDisplay == .remaining ? .on : .off
        menu.addItem(remainingItem)

        // 菜单栏显示哪些窗口（余额型供应商不受此项影响）
        let windowItem = NSMenuItem(title: "菜单栏显示窗口", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu()
        for name in [QuotaWindow.fiveHour, QuotaWindow.weekly, QuotaWindow.monthly, QuotaWindow.credits] {
            let entry = NSMenuItem(title: name, action: #selector(toggleWindow(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = name
            entry.state = prefs.isStatusWindowEnabled(name) ? .on : .off
            windowMenu.addItem(entry)
        }
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)

        // 每家一个状态栏项 vs 合并为一个
        let perProvider = NSMenuItem(title: "每家单独一个菜单栏项", action: #selector(togglePerProvider), keyEquivalent: "")
        perProvider.target = self
        perProvider.state = prefs.statusItemPerProvider ? .on : .off
        menu.addItem(perProvider)

        // 钉住某一家
        let pinItem = NSMenuItem(title: "菜单栏固定显示", action: nil, keyEquivalent: "")
        let pinMenu = NSMenu()
        let auto = NSMenuItem(title: "自动（使用率最高）", action: #selector(pinFocus(_:)), keyEquivalent: "")
        auto.target = self
        auto.representedObject = ""
        auto.state = prefs.statusItemFocus == nil ? .on : .off
        pinMenu.addItem(auto)
        for kind in ProviderKind.displayOrder where prefs.isEnabled(kind) {
            let entry = NSMenuItem(title: kind.displayName, action: #selector(pinFocus(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = kind.rawValue
            entry.state = prefs.statusItemFocus == kind ? .on : .off
            pinMenu.addItem(entry)
        }
        pinItem.submenu = pinMenu
        menu.addItem(pinItem)

        menu.addItem(.separator())
        let refresh = NSMenuItem(title: isRefreshing ? "刷新中…" : "立即刷新", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        refresh.isEnabled = !isRefreshing
        menu.addItem(refresh)

        let open = NSMenuItem(title: "打开主窗口", action: #selector(openMainWindow), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let quit = NSMenuItem(title: "退出 QuotaBar", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        if let latest = lastUsages.map(\.queryDate).max() {
            menu.addItem(.separator())
            menu.addItem(disabled("更新于 " + Self.timeText(latest)))
        }
        return menu
    }

    private static func menuTitle(_ usage: ProviderUsage, prefs: DisplayPreferences) -> String {
        guard usage.ok else { return "\(usage.kind.displayName) · 查询失败" }
        var parts: [String] = [usage.kind.displayName]
        if let subtitle = usage.subtitle, !subtitle.isEmpty { parts.append(subtitle) }
        // 全部窗口都列出来（原来只给主窗口，5 小时之后的周/月看不到）
        for window in usage.windowsInDisplayOrder {
            parts.append("\(window.shortName) \(prefs.displayedPercent(window).percentText)")
        }
        // 余额型（DeepSeek / CommandCode credits）单独给一行金额
        if let balance = usage.balanceText { parts.append("余额 \(balance)") }
        if let window = usage.windowsInDisplayOrder.last, !window.resetCaption.isEmpty {
            parts.append(window.resetCaption)
        } else if let window = usage.primaryWindow, !window.resetCaption.isEmpty {
            parts.append(window.resetCaption)
        }
        return parts.joined(separator: " · ")
    }

    private func smallIcon(_ kind: ProviderKind, level: Double?) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        guard let image = NSImage(systemSymbolName: kind.iconSymbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        image.isTemplate = true
        return image
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    // MARK: - 动作

    @objc private func openConsole(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let kind = ProviderKind(rawValue: raw),
              let url = URL(string: kind.consoleURL) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleKind(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let kind = ProviderKind(rawValue: raw) else { return }
        var prefs = DisplayStore.load()
        prefs.setEnabled(kind, !prefs.isEnabled(kind))
        // 不允许把全部关掉——全关等于没有可显示内容，直接退回「全部显示」
        if prefs.enabledKinds.isEmpty { prefs.enabledKinds = [] }
        persistAndBroadcast(prefs)
    }

    @objc private func showAll() {
        var prefs = DisplayStore.load()
        prefs.enabledKinds = []
        persistAndBroadcast(prefs)
    }

    @objc private func togglePercent() {
        var prefs = DisplayStore.load()
        prefs.statusItemShowsPercent.toggle()
        persistAndBroadcast(prefs)
    }

    @objc private func toggleWindow(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        var prefs = DisplayStore.load()
        prefs.setStatusWindow(name, !prefs.isStatusWindowEnabled(name))
        persistAndBroadcast(prefs)
    }

    @objc private func setDisplayUsed() {
        var prefs = DisplayStore.load()
        guard prefs.quotaDisplay != .used else { return }
        prefs.quotaDisplay = .used
        persistAndBroadcast(prefs)
    }

    @objc private func setDisplayRemaining() {
        var prefs = DisplayStore.load()
        guard prefs.quotaDisplay != .remaining else { return }
        prefs.quotaDisplay = .remaining
        persistAndBroadcast(prefs)
    }

    @objc private func togglePerProvider() {
        var prefs = DisplayStore.load()
        prefs.statusItemPerProvider.toggle()
        persistAndBroadcast(prefs)
    }

    @objc private func pinFocus(_ sender: NSMenuItem) {
        var prefs = DisplayStore.load()
        let raw = (sender.representedObject as? String) ?? ""
        prefs.statusItemFocus = raw.isEmpty ? nil : ProviderKind(rawValue: raw)
        persistAndBroadcast(prefs)
    }

    private func persistAndBroadcast(_ prefs: DisplayPreferences) {
        DisplayStore.save(prefs)
        NotificationCenter.default.post(name: .displayPreferencesChanged, object: nil)
        reloadFromCache()
        WidgetCenter.shared.reloadAllTimelines()
    }

    @objc private func refreshNow() {
        guard let action = refreshAction, !isRefreshing else { return }
        isRefreshing = true
        render()
        Task { @MainActor in
            await action()
            isRefreshing = false
            reloadFromCache()
        }
    }

    @objc private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // WindowGroup 的窗口在收起后可能不可见，这里统一按窗口列表恢复
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible == false })
            ?? NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension Notification.Name {
    /// 快照变化，状态栏据此重画（由 App 查询完成 / 偏好变化时发出）
    static let statusBarShouldRefresh = Notification.Name("QuotaBar.statusBarShouldRefresh")
}
