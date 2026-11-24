import WidgetKit
import SwiftUI
import AppIntents

/// 小组件上的手动刷新按钮：查询后写快照，系统随后自动重载时间线，
/// getTimeline 发现快照很新就直接复用，不再重复请求。
struct RefreshUsageIntent: AppIntent {
    static let title: LocalizedStringResource = "刷新 API 用量"
    static let description = IntentDescription("重新查询已勾选的供应商额度并更新小组件")

    func perform() async throws -> some IntentResult {
        let prefs = DisplayStore.load()
        let credentials = ProvidersStore.loadCredentials().filter { prefs.shouldQuery($0.kind) }
        let results = await QueryService.fetchAll(credentials)
        if !results.isEmpty { SnapshotCache.save(results) }
        return .result()
    }
}

struct UsageEntry: TimelineEntry {
    let date: Date
    let usages: [ProviderUsage]
    let usedCache: Bool

    static let sample = UsageEntry(date: Date(), usages: [
        ProviderUsage(kind: .volcengine, ok: true, windows: [
            QuotaWindow(name: QuotaWindow.monthly, percent: 80.9, resetTime: Date().addingTimeInterval(86400 * 1.2)),
            QuotaWindow(name: QuotaWindow.weekly, percent: 5.6, resetTime: Date().addingTimeInterval(86400 * 3)),
            QuotaWindow(name: QuotaWindow.fiveHour, percent: 1.5, resetTime: Date().addingTimeInterval(7200)),
        ], subtitle: "Coding Plan"),
        ProviderUsage(kind: .zhipu, ok: true, windows: [
            QuotaWindow(name: QuotaWindow.weekly, percent: 23.4, used: 2343, total: 10000, unit: "积分",
                        resetTime: Date().addingTimeInterval(86400 * 2), remainingOverride: 7657),
            QuotaWindow(name: QuotaWindow.fiveHour, percent: 12, used: 240, total: 2000, unit: "积分",
                        resetTime: Date().addingTimeInterval(3600), remainingOverride: 1760),
        ], subtitle: "Coding Plan (lite)"),
        ProviderUsage(kind: .deepseek, ok: true, subtitle: "余额",
                      balance: 11.3, currency: "CNY", isAvailable: true),
    ], usedCache: false)
}

struct UsageTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry { .sample }

    /// 小组件库预览走缓存，避免阻塞
    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        if let cached = SnapshotCache.load(), !cached.isEmpty {
            completion(UsageEntry(date: Date(), usages: ordered(cached), usedCache: false))
        } else {
            completion(.sample)
        }
    }

    /// 每次刷新：读凭据 → 并发查询已勾选的供应商 → 写缓存 → 15 分钟后再刷。
    /// 两分钟内刚被刷新按钮或 App 查询过的快照直接复用。
    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date())
            ?? Date().addingTimeInterval(900)
        let prefs = DisplayStore.load()
        if let cached = SnapshotCache.load(), !cached.isEmpty,
           let latest = cached.map(\.queryDate).max(),
           Date().timeIntervalSince(latest) < 120 {
            let entry = UsageEntry(date: Date(), usages: prefs.filter(cached), usedCache: false)
            completion(Timeline(entries: [entry], policy: .after(next)))
            return
        }
        let credentials = ProvidersStore.loadCredentials().filter { prefs.shouldQuery($0.kind) }
        Task {
            var usages = await QueryService.fetchAll(credentials)
            var usedCache = false
            if usages.isEmpty {
                usages = SnapshotCache.load() ?? []
                usedCache = true
            } else {
                let cached = SnapshotCache.load() ?? []
                usages = usages.map { usage in
                    guard !usage.ok,
                          let good = cached.first(where: { $0.kind == usage.kind && $0.ok }) else { return usage }
                    usedCache = true
                    return good
                }
            }
            usages = prefs.filter(usages)
            if !usages.isEmpty { SnapshotCache.save(usages) }
            let entry = UsageEntry(date: Date(), usages: usages, usedCache: usedCache)
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    private func ordered(_ list: [ProviderUsage]) -> [ProviderUsage] {
        let order = ProviderKind.displayOrder
        return order.compactMap { kind in list.first { $0.kind == kind } }
            + list.filter { !order.contains($0.kind) }
    }
}

struct ApiUsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ApiUsageShowWidget", provider: UsageTimelineProvider()) { entry in
            ApiUsageWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("API 用量")
        .description("火山方舟 · 智谱 GLM 的 5小时 / 7天 / 月额度与重置时间，DeepSeek 余额")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
