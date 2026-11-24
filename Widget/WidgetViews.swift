import SwiftUI
import WidgetKit

struct ApiUsageWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: UsageEntry

    var body: some View {
        Group {
            switch family {
            case .systemLarge:
                LargeUsageView(usages: entry.usages, usedCache: entry.usedCache, date: entry.date)
            case .systemMedium:
                MediumUsageView(usages: entry.usages, usedCache: entry.usedCache)
            default:
                SmallUsageView(usages: entry.usages)
            }
        }
        .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
    }
}

// MARK: - 空状态 / 刷新按钮

private struct EmptyUsageView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("暂无数据，打开 API Usage 应用")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 交互式小组件按钮：点按执行 RefreshUsageIntent（不能嵌在 Link 里）
private struct RefreshButton: View {
    var size: CGFloat = 10

    var body: some View {
        Button(intent: RefreshUsageIntent()) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: size + 10, height: size + 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 中号：窗口型供应商按列排，余额型收在底部

struct MediumUsageView: View {
    var usages: [ProviderUsage]
    var usedCache: Bool

    private var windowProviders: [ProviderUsage] { usages.filter { $0.kind != .deepseek } }
    private var balances: [ProviderUsage] { usages.filter { $0.kind == .deepseek } }

    var body: some View {
        if usages.isEmpty {
            EmptyUsageView()
        } else {
            VStack(spacing: 2) {
                HStack(alignment: .top, spacing: 8) {
                    if let first = windowProviders.first {
                        ProviderColumn(usage: first)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    if windowProviders.count > 1 || !balances.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 4) {
                            if windowProviders.count > 1 {
                                ProviderColumn(usage: windowProviders[1])
                            }
                            if let balance = balances.first {
                                if windowProviders.count > 1 { Divider() }
                                BalanceRow(usage: balance)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                // 超过两家的窗口型（OpenCode Go / CommandCode）压成一行紧凑摘要，避免中号放不下
                if windowProviders.count > 2 {
                    HStack(spacing: 6) {
                        ForEach(windowProviders.dropFirst(2)) { usage in
                            CompactQuotaChip(usage: usage)
                        }
                        Spacer(minLength: 0)
                    }
                }
                HStack(spacing: 4) {
                    RefreshButton(size: 8.5)
                    Spacer(minLength: 2)
                    if usedCache {
                        Text("缓存数据 · 稍后自动刷新")
                            .font(.system(size: 7.5))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
    }
}

/// 中号底部的一行紧凑摘要：图标 + 名称 + 主窗口百分比（多出来的供应商用它，不挤掉主要两栏）
private struct CompactQuotaChip: View {
    var usage: ProviderUsage

    var body: some View {
        Link(destination: URL(string: usage.kind.consoleURL)!) {
            HStack(spacing: 3) {
                Image(systemName: usage.kind.iconSymbol)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(usage.kind.brandColor)
                Text(usage.kind.displayName)
                    .font(.system(size: 8, weight: .medium))
                    .lineLimit(1)
                if usage.ok, let window = usage.primaryWindow {
                    Text(window.percent.percentText)
                        .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(levelColor(window.percent))
                } else {
                    Text(usage.ok ? "—" : "失败")
                        .font(.system(size: 8))
                        .foregroundStyle(.red)
                }
            }
            .contentShape(Rectangle())
        }
    }
}

/// 一栏：头部 + 全部窗口行（按 5小时 → 7天 → 月）
private struct ProviderColumn: View {
    var usage: ProviderUsage

    var body: some View {
        Link(destination: URL(string: usage.kind.consoleURL)!) {
            VStack(alignment: .leading, spacing: 4) {
                ProviderHeader(usage: usage, compact: true)
                if usage.ok {
                    ForEach(usage.windowsInDisplayOrder) { window in
                        QuotaWindowRow(window: window, style: .compact)
                    }
                } else {
                    Text(usage.errorMessage ?? "查询失败")
                        .font(.system(size: 8.5))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            .contentShape(Rectangle())
        }
    }
}

/// DeepSeek 余额行（中号右栏底部）
private struct BalanceRow: View {
    var usage: ProviderUsage

    var body: some View {
        Link(destination: URL(string: usage.kind.consoleURL)!) {
            VStack(alignment: .leading, spacing: 2) {
                ProviderHeader(usage: usage, compact: true)
                HStack(spacing: 4) {
                    Text(statusText)
                        .font(.system(size: 8.5))
                        .foregroundStyle(usage.ok ? Color.secondary : Color.red)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Text("更新 " + usage.timeCaption)
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                }
                .padding(.leading, 24)
            }
            .contentShape(Rectangle())
        }
    }

    private var statusText: String {
        guard usage.ok else { return usage.errorMessage ?? "查询失败" }
        return usage.isAvailable == false ? "余额 · 服务异常" : "余额 · 服务可用"
    }
}

// MARK: - 大号：全部供应商完整窗口

struct LargeUsageView: View {
    var usages: [ProviderUsage]
    var usedCache: Bool
    var date: Date

    var body: some View {
        if usages.isEmpty {
            EmptyUsageView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("API 用量")
                        .font(.system(size: 13, weight: .bold))
                    Spacer()
                    Text((usedCache ? "缓存 · " : "更新 ") + Self.timeText(date))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    RefreshButton(size: 10)
                }
                // provider 之间均分剩余高度（原来靠底部模型页脚收尾，页脚删掉后靠间距撑开）
                ForEach(usages) { usage in
                    ProviderSection(usage: usage)
                    if usage.id != usages.last?.id {
                        Spacer(minLength: 4)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
    }

    private static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

/// 大号里的一个 provider 分区：头部 + 窗口行 / 余额说明
private struct ProviderSection: View {
    var usage: ProviderUsage

    var body: some View {
        Link(destination: URL(string: usage.kind.consoleURL)!) {
            VStack(alignment: .leading, spacing: 5) {
                ProviderHeader(usage: usage)
                if !usage.ok {
                    Text(usage.errorMessage ?? "查询失败")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .padding(.leading, 30)
                } else if usage.kind == .deepseek {
                    Text(usage.isAvailable == false ? "账户余额 · 服务异常" : "账户余额 · 服务可用 · 更新 \(usage.timeCaption)")
                        .font(.system(size: 9.5))
                        .foregroundStyle(usage.isAvailable == false ? Color.red : Color.secondary)
                        .padding(.leading, 30)
                } else {
                    if let balance = usage.balanceText {
                        // CommandCode：credits 池余额比百分比更该被看到
                        Text("剩余额度 \(balance) · 更新 \(usage.timeCaption)")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 30)
                    }
                    ForEach(usage.windowsInDisplayOrder) { window in
                        QuotaWindowRow(window: window, style: .regular)
                    }
                    .padding(.leading, 30)
                }
            }
            .contentShape(Rectangle())
        }
    }
}

// MARK: - 小号：用量最高的 provider

struct SmallUsageView: View {
    var usages: [ProviderUsage]

    private var focus: ProviderUsage? {
        usages.filter { $0.ok && !$0.windows.isEmpty }
            .max { ($0.windows.first?.percent ?? 0) < ($1.windows.first?.percent ?? 0) }
            ?? usages.first { $0.ok }
            ?? usages.first
    }

    var body: some View {
        VStack(spacing: 6) {
            if let usage = focus {
                HStack(spacing: 5) {
                    Image(systemName: usage.kind.iconSymbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(usage.kind.brandColor)
                    Text(usage.kind.displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    if usage.ok, let primary = usage.primaryWindow {
                        Text("· \(primary.name)")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 2)
                    RefreshButton(size: 8.5)
                }
                if usage.ok, usage.kind == .deepseek, let text = usage.balanceText {
                    Spacer()
                    Text(text)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.6)
                    Spacer()
                    Text(usage.isAvailable == false ? "服务异常" : "余额")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                } else if let primary = usage.primaryWindow, usage.ok {
                    Spacer()
                    ring(percent: primary.percent)
                    Spacer()
                    Text(primary.remainingText)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(primary.resetCaption)
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else {
                    Spacer()
                    Text(usage.ok ? "无窗口数据" : (usage.errorMessage ?? "查询失败"))
                        .font(.system(size: 9))
                        .foregroundStyle(usage.ok ? Color.secondary : Color.red)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
            } else {
                Spacer()
                Text("暂无数据")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("打开 API Usage 应用")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .padding(6)
        .widgetURL(URL(string: focus?.kind.consoleURL ?? ProviderKind.volcengine.consoleURL))
    }

    private func ring(percent: Double) -> some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 9)
            Circle()
                .trim(from: 0, to: min(max(percent / 100, 0), 1))
                .stroke(levelColor(percent), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 58, height: 58)
        .overlay(
            Text(percent.percentText)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.7)
        )
    }
}
