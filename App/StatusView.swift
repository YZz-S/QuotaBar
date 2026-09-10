import SwiftUI
import WidgetKit

/// 「用量」页：识别到的查询配置、立即查询、三家额度富展示、添加小组件引导
struct StatusView: View {
    @State private var credentials: [ProviderCredentials] = []
    @State private var results: [ProviderUsage] = []
    @State private var running = false
    @State private var dbFound = true
    @State private var fromCache = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "widget.small")
                        .font(.title2)
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("API 用量小组件").font(.headline)
                        Text("凭据自动来自 cc-switch（\(ProvidersStore.dbURL.path)）")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                }

                credentialsSection

                Divider()

                HStack(spacing: 10) {
                    Button {
                        runTest()
                    } label: {
                        HStack(spacing: 5) {
                            if running {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text(running ? "查询中…" : "立即查询全部")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(running || credentials.isEmpty)
                    if let first = results.first {
                        Text((fromCache ? "上次查询 " : "查询于 ") + first.timeCaption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                ForEach(results) { usage in
                    UsageCard(usage: usage)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("添加小组件：在桌面或通知中心右键 →「编辑」→ 搜索「API 用量」，提供小 / 中 / 大三种尺寸。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("数据由小组件自行刷新（系统预算约 15 分钟）；打开本应用会触发一次立即刷新。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(18)
        }
        .task {
            dbFound = FileManager.default.fileExists(atPath: ProvidersStore.dbURL.path)
            credentials = ProvidersStore.loadCredentials()
            ProvidersStore.exportCredentials(credentials)
            if let cached = SnapshotCache.load(), !cached.isEmpty {
                results = cached
                fromCache = true
            }
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    @ViewBuilder private var credentialsSection: some View {
        if !dbFound {
            Label("未找到 cc-switch 数据库（~/.cc-switch/cc-switch.db）", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
        } else if credentials.isEmpty {
            Label("未识别到已启用用量查询的 provider，请先在 cc-switch 中为对应 provider 配置用量查询。", systemImage: "magnifyingglass")
                .foregroundStyle(.orange)
                .font(.callout)
        } else {
            VStack(spacing: 6) {
                ForEach(credentials, id: \.kind) { credential in
                    HStack(spacing: 9) {
                        Image(systemName: credential.kind.iconSymbol)
                            .foregroundStyle(credential.kind.brandColor)
                            .frame(width: 22)
                        Text(credential.kind.displayName).fontWeight(.medium)
                        Text("← \(credential.sourceName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                        Text(credential.keyDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func runTest() {
        running = true
        Task {
            let fresh = ProvidersStore.loadCredentials()
            if !fresh.isEmpty {
                credentials = fresh
                ProvidersStore.exportCredentials(fresh)
            }
            let fetched = await QueryService.fetchAll(credentials)
            if !fetched.isEmpty { SnapshotCache.save(fetched) }
            results = fetched
            fromCache = false
            running = false
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}

/// 一家 provider 的额度卡：头部 + 各窗口（5小时 / 7天 / 月）剩余与重置时间，或余额说明
private struct UsageCard: View {
    var usage: ProviderUsage

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 7) {
                if !usage.ok {
                    Label(usage.errorMessage ?? "查询失败", systemImage: "xmark.octagon.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if usage.kind == .deepseek {
                    HStack(spacing: 6) {
                        Image(systemName: usage.isAvailable == false ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(usage.isAvailable == false ? Color.orange : Color.green)
                        Text(usage.isAvailable == false ? "账户余额 · 服务异常" : "账户余额 · 服务可用")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("更新 " + usage.timeCaption)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } else if usage.windows.isEmpty {
                    Text("无窗口数据")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(usage.windowsInDisplayOrder) { window in
                        QuotaWindowRow(window: window, style: .regular)
                    }
                }
            }
            .padding(.top, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 8) {
                ProviderHeader(usage: usage)
                Link(destination: URL(string: usage.kind.consoleURL)!) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                }
                .help("打开控制台")
            }
        }
    }
}
