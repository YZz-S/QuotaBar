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

// MARK: - 空状态

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

// MARK: - 中号：两栏（左 火山三窗口 / 右 智谱两窗口 + DeepSeek 余额）

struct MediumUsageView: View {
    var usages: [ProviderUsage]
    var usedCache: Bool

    private var windowProviders: [ProviderUsage] { usages.filter { $0.kind != .deepseek } }
    private var deepseek: ProviderUsage? { usages.first { $0.kind == .deepseek } }

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
                    if windowProviders.count > 1 || deepseek != nil {
                        Divider()
                        VStack(alignment: .leading, spacing: 4) {
                            if windowProviders.count > 1 {
                                ProviderColumn(usage: windowProviders[1])
                            }
                            if let deepseek {
                                if windowProviders.count > 1 { Divider() }
                                BalanceRow(usage: deepseek)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                if usedCache {
                    Text("缓存数据 · 稍后自动刷新")
                        .font(.system(size: 7.5))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
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

// MARK: - 大号：三家完整窗口 + 支持模型

struct LargeUsageView: View {
    var usages: [ProviderUsage]
    var usedCache: Bool
    var date: Date

    var body: some View {
        if usages.isEmpty {
            EmptyUsageView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("API 用量")
                        .font(.system(size: 13, weight: .bold))
                    Spacer()
                    Text((usedCache ? "缓存 · " : "更新 ") + Self.timeText(date))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                ForEach(usages) { usage in
                    ProviderSection(usage: usage)
                }
                Spacer(minLength: 0)
                modelsFooter
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
    }

    private var modelsFooter: some View {
        VStack(alignment: .leading, spacing: 2) {
            Divider()
            footerLine(icon: ProviderKind.volcengine.iconSymbol, color: ProviderKind.volcengine.brandColor,
                       label: "方舟支持", text: ModelCatalog.ark.summary)
            footerLine(icon: ProviderKind.zhipu.iconSymbol, color: ProviderKind.zhipu.brandColor,
                       label: "GLM 支持", text: ModelCatalog.glm.summary)
        }
    }

    private func footerLine(icon: String, color: Color, label: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 7.5))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
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
