import SwiftUI

/// App 与 widget 共用的展示辅助（不进 CLI 编译单元，依赖 SwiftUI）
extension ProviderKind {
    var iconSymbol: String {
        switch self {
        case .volcengine: return "flame.fill"
        case .zhipu: return "sparkles"
        case .deepseek: return "yensign.circle.fill"
        }
    }

    var brandColor: Color {
        switch self {
        case .volcengine: return .orange
        case .zhipu: return .blue
        case .deepseek: return .purple
        }
    }
}

func levelColor(_ percent: Double) -> Color {
    if percent >= 80 { return .red }
    if percent >= 50 { return .orange }
    return .green
}

extension Double {
    var groupedInt: String { formatted(.number.precision(.fractionLength(0))) }
    var money2: String { formatted(.number.precision(.fractionLength(2))) }
    /// 百分比：整数不带小数，非整数保留 1 位（80.9% / 5%）
    var percentText: String { formatted(.number.precision(.fractionLength(0...1))) + "%" }
}

extension QuotaWindow {
    var fraction: Double { min(max(percent / 100, 0), 1) }

    /// 剩余额度：有绝对值显示「余 1,760 积分」，火山仅给百分比时显示「余 19.1%」
    var remainingText: String {
        if let remaining {
            return "余 " + remaining.groupedInt + (unit.map { " \($0)" } ?? "")
        }
        return "余 " + max(0, 100 - percent).percentText
    }

    /// 已用 / 总量文案「2,343 / 10,000 积分」，无绝对值时为 nil
    var usageText: String? {
        guard let used, let total, total > 0 else { return nil }
        return "\(used.groupedInt) / \(total.groupedInt)" + (unit.map { " \($0)" } ?? "")
    }

    /// 相对重置时间「2小时后重置」
    var resetCaption: String {
        guard let resetTime else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: resetTime, relativeTo: Date()) + "重置"
    }

    /// 绝对重置时间：当天显示「14:00」，否则「09-12 08:00」
    var resetAbsolute: String? {
        guard let resetTime else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = Calendar.current.isDateInToday(resetTime) ? "HH:mm" : "MM-dd HH:mm"
        return formatter.string(from: resetTime)
    }
}

extension ProviderUsage {
    var primaryWindow: QuotaWindow? { windows.first }
    var fraction: Double? { primaryWindow.map { $0.fraction } }
    var primaryLevelColor: Color? { primaryWindow.map { levelColor($0.percent) } }

    var balanceText: String? {
        guard let balance else { return nil }
        let symbol = currency == "CNY" ? "¥" : ((currency.map { $0 + " " }) ?? "")
        return symbol + balance.money2
    }

    var timeCaption: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: queryDate)
    }
}

// MARK: - 共用视图

/// 单个额度窗口：第一行 名称 + 进度条 + 百分比，第二行 剩余 + 重置时间。
/// compact 供中号小组件（两栏），regular 供大号小组件与 App。
struct QuotaWindowRow: View {
    enum Style { case compact, regular }

    var window: QuotaWindow
    var style: Style = .regular

    private var nameSize: CGFloat { style == .compact ? 9.5 : 11 }
    private var detailSize: CGFloat { style == .compact ? 8.5 : 9.5 }
    private var labelWidth: CGFloat { style == .compact ? 30 : 36 }
    private var percentWidth: CGFloat { style == .compact ? 34 : 42 }
    private var barGap: CGFloat { style == .compact ? 5 : 7 }

    var body: some View {
        VStack(alignment: .leading, spacing: style == .compact ? 1 : 2.5) {
            HStack(spacing: barGap) {
                Text(window.name)
                    .font(.system(size: nameSize, weight: .semibold))
                    .frame(width: labelWidth, alignment: .leading)
                ProgressView(value: window.fraction)
                    .progressViewStyle(.linear)
                    .tint(levelColor(window.percent))
                Text(window.percent.percentText)
                    .font(.system(size: nameSize, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(levelColor(window.percent))
                    .frame(width: percentWidth, alignment: .trailing)
            }
            HStack(spacing: 4) {
                Text(detailText)
                    .font(.system(size: detailSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text(resetText)
                    .font(.system(size: detailSize))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.leading, labelWidth + barGap)
        }
    }

    private var detailText: String {
        if style == .regular, let usage = window.usageText {
            return window.remainingText + " · 已用 " + usage
        }
        return window.remainingText
    }

    private var resetText: String {
        if style == .regular, let absolute = window.resetAbsolute, !window.resetCaption.isEmpty {
            return window.resetCaption + "（\(absolute)）"
        }
        return window.resetCaption
    }
}

/// provider 头部：品牌圆标 + 名称 + 副标题 + 右侧汇总（主窗口百分比 / 余额 / 失败）
struct ProviderHeader: View {
    var usage: ProviderUsage
    var compact: Bool = false

    var body: some View {
        HStack(spacing: compact ? 6 : 8) {
            Image(systemName: usage.kind.iconSymbol)
                .font(.system(size: compact ? 9.5 : 11, weight: .semibold))
                .foregroundStyle(usage.kind.brandColor)
                .frame(width: compact ? 18 : 22, height: compact ? 18 : 22)
                .background(usage.kind.brandColor.opacity(0.14), in: Circle())
            Text(usage.kind.displayName)
                .font(.system(size: compact ? 10.5 : 12, weight: .semibold))
                .lineLimit(1)
            if let subtitle = usage.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: compact ? 8 : 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            trailing
        }
    }

    @ViewBuilder private var trailing: some View {
        if !usage.ok {
            Text("查询失败")
                .font(.system(size: compact ? 8.5 : 9.5, weight: .semibold))
                .foregroundStyle(.red)
        } else if let text = usage.balanceText {
            Text(text)
                .font(.system(size: compact ? 12 : 14, weight: .bold, design: .rounded))
                .monospacedDigit()
        } else if let primary = usage.primaryWindow {
            Text(primary.percent.percentText)
                .font(.system(size: compact ? 11 : 12.5, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(levelColor(primary.percent))
        }
    }
}
