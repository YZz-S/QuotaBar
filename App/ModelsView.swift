import SwiftUI

/// 「模型」页：方舟 / GLM Coding Plan 支持模型、DeepSeek 模型与价格、OpenCode Go 模型表
struct ModelsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "cpu")
                        .font(.title2)
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("支持的模型与价格").font(.headline)
                        Text("静态资料，核对于 \(ModelCatalog.asOf)；点击各区标题右侧链接查看官方最新信息")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                arkSection
                glmSection
                deepseekSection
                opencodeSection
            }
            .padding(18)
        }
    }

    // MARK: 方舟 Coding Plan

    private var arkSection: some View {
        let plan = ModelCatalog.ark
        return CatalogSection(title: plan.title, subtitle: plan.subtitle,
                              icon: ProviderKind.volcengine.iconSymbol, color: ProviderKind.volcengine.brandColor,
                              links: [.init(label: "官方活动页", url: plan.sourceURL)]) {
            ChipList(items: plan.models, color: ProviderKind.volcengine.brandColor)
            NotesList(notes: plan.notes)
        }
    }

    // MARK: GLM Coding Plan

    private var glmSection: some View {
        let plan = ModelCatalog.glm
        return CatalogSection(title: plan.title, subtitle: plan.subtitle,
                              icon: ProviderKind.zhipu.iconSymbol, color: ProviderKind.zhipu.brandColor,
                              links: [.init(label: "套餐概览", url: plan.sourceURL)]) {
            ChipList(items: plan.models, color: ProviderKind.zhipu.brandColor)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text("积分系数 / 万 tokens").gridColumnAlignment(.leading)
                    Text("输入")
                    Text("缓存命中")
                    Text("输出")
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                ForEach(plan.creditRates) { rate in
                    GridRow {
                        Text(rate.model).fontWeight(.medium)
                        Text(rate.input)
                        Text(rate.cached)
                        Text(rate.output)
                    }
                    .font(.caption)
                    .monospacedDigit()
                }
            }
            .padding(.top, 2)
            NotesList(notes: plan.notes)
        }
    }

    // MARK: DeepSeek

    private var deepseekSection: some View {
        let platform = ModelCatalog.deepseek
        return CatalogSection(title: platform.title, subtitle: platform.subtitle,
                              icon: ProviderKind.deepseek.iconSymbol, color: ProviderKind.deepseek.brandColor,
                              links: [.init(label: "模型 & 价格", url: platform.sourceURL)]) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("模型").gridColumnAlignment(.leading)
                    Text("输入 · 缓存命中")
                    Text("输入 · 未命中")
                    Text("输出")
                    Text("并发")
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(platform.models) { model in
                    GridRow(alignment: .top) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.name).font(.caption).fontWeight(.medium)
                            Text(model.version).font(.system(size: 9)).foregroundStyle(.tertiary)
                            Text(model.context).font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                        PeakPrice(pair: model.inputCacheHit)
                        PeakPrice(pair: model.inputCacheMiss)
                        PeakPrice(pair: model.output)
                        Text(model.concurrency).font(.caption).monospacedDigit()
                    }
                }
            }
            NotesList(notes: platform.notes)
        }
    }

    // MARK: OpenCode Go

    private var opencodeSection: some View {
        let plan = ModelCatalog.opencodeGo
        return CatalogSection(title: plan.title, subtitle: plan.subtitle,
                              icon: "terminal.fill", color: .teal,
                              links: [.init(label: "产品页", url: plan.homeURL), .init(label: "模型文档", url: plan.sourceURL)]) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                GridRow {
                    Text("模型").gridColumnAlignment(.leading)
                    Text("输入")
                    Text("输出")
                    Text("缓存读")
                    Text("月上限")
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(plan.models) { model in
                    GridRow {
                        Text(model.name).fontWeight(.medium).lineLimit(1)
                        Text(model.input)
                        Text(model.output)
                        Text(model.cachedRead)
                        Text(model.monthlyLimit)
                    }
                    .font(.caption)
                    .monospacedDigit()
                }
            }
            NotesList(notes: plan.notes)
        }
    }
}

// MARK: - 组件

/// 一个资料分区：标题行（图标 + 标题 + 副标题 + 外链）+ 内容
private struct CatalogSection<Content: View>: View {
    var title: String
    var subtitle: String
    var icon: String
    var color: Color
    var links: [ModelCatalog.ExternalLink]
    @ViewBuilder var content: () -> Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 22, height: 22)
                    .background(color.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                ForEach(links) { link in
                    Link(destination: link.url) {
                        Label(link.label, systemImage: "arrow.up.right.square")
                            .font(.caption)
                    }
                }
            }
        }
    }
}

/// 模型名标签流式排列
private struct ChipList: View {
    var items: [String]
    var color: Color

    var body: some View {
        WrapLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(color.opacity(0.12), in: Capsule())
                    .overlay(Capsule().stroke(color.opacity(0.35), lineWidth: 0.5))
            }
        }
    }
}

/// 说明要点列表
private struct NotesList: View {
    var notes: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(notes, id: \.self) { note in
                HStack(alignment: .top, spacing: 5) {
                    Text("•").foregroundStyle(.tertiary)
                    Text(note)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// 空闲 / 高峰 双价
private struct PeakPrice: View {
    var pair: (offPeak: String, peak: String)

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("¥" + pair.offPeak).font(.caption).monospacedDigit()
            Text("高峰 ¥" + pair.peak).font(.system(size: 9)).foregroundStyle(.tertiary).monospacedDigit()
        }
    }
}

/// 简单的流式布局（自动换行）
private struct WrapLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
