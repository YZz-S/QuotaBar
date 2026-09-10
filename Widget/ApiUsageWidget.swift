import WidgetKit
import SwiftUI

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

    /// 每次刷新：读 cc-switch 凭据 → 并发查询三家 → 写缓存 → 15 分钟后再刷
    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let credentials = ProvidersStore.loadCredentials()
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
            if !usages.isEmpty { SnapshotCache.save(usages) }
            let entry = UsageEntry(date: Date(), usages: usages, usedCache: usedCache)
            let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date())
                ?? Date().addingTimeInterval(900)
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    private func ordered(_ list: [ProviderUsage]) -> [ProviderUsage] {
        let order: [ProviderKind] = [.volcengine, .zhipu, .deepseek]
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
