import SwiftUI
import WidgetKit

/// 「用量」页：识别到的查询配置、立即查询、三家额度富展示、添加小组件引导
struct StatusView: View {
    @State private var credentials: [ProviderCredentials] = []
    @State private var results: [ProviderUsage] = []
    @State private var running = false
    @State private var dbFound = true
    @State private var fromCache = false
    @State private var prefs = DisplayStore.load()

    /// 按「显示哪些供应商」偏好筛出的凭据（顺序固定）
    private var activeCredentials: [ProviderCredentials] {
        credentials.filter { prefs.shouldQuery($0.kind) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "widget.small")
                        .font(.title2)
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("QuotaBar").font(.headline)
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
                    .disabled(running || activeCredentials.isEmpty)
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
            prefs = DisplayStore.load()
            ProvidersStore.exportCredentials(credentials)
            if let cached = SnapshotCache.load(), !cached.isEmpty {
                results = prefs.filter(cached)
                fromCache = true
            }
            WidgetCenter.shared.reloadAllTimelines()
            QuotaAlertCenter.shared.start()
        }
        .onReceive(NotificationCenter.default.publisher(for: .credentialsChanged)) { _ in
            credentials = ProvidersStore.loadCredentials()
        }
        .onReceive(NotificationCenter.default.publisher(for: .displayPreferencesChanged)) { _ in
            prefs = DisplayStore.load()
            if let cached = SnapshotCache.load(), !cached.isEmpty {
                results = prefs.filter(cached)
            }
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
                HStack(spacing: 6) {
                    Text("显示哪些供应商")
                        .font(.caption.weight(.semibold))
                    Text(prefs.isAllEnabled ? "（全部）" : "（\(prefs.activeKinds.count)/\(ProviderKind.displayOrder.count)）")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Toggle("连未选中的也查询", isOn: Binding(
                        get: { prefs.queryUnselected },
                        set: { on in
                            prefs.queryUnselected = on
                            DisplayStore.save(prefs)
                            NotificationCenter.default.post(name: .displayPreferencesChanged, object: nil)
                        }))
                        .toggleStyle(.checkbox)
                        .font(.caption2)
                }
                ForEach(credentials, id: \.kind) { credential in
                    let known = credential.kind
                    HStack(spacing: 9) {
                        // get 必须现算 prefs.isEnabled(known)，不能捕获循环体里的局部常量：
                        // 捕获的话取消勾选后 get 仍返回旧值，复选框看起来「点不动」
                        Toggle("", isOn: Binding(
                            get: { prefs.isEnabled(known) },
                            set: { newValue in
                                prefs.setEnabled(known, newValue)
                                DisplayStore.save(prefs)
                                NotificationCenter.default.post(name: .displayPreferencesChanged, object: nil)
                            }))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                        Image(systemName: credential.kind.iconSymbol)
                            .foregroundStyle(prefs.isEnabled(known) ? credential.kind.brandColor : Color.secondary)
                            .frame(width: 22)
                        Text(credential.kind.displayName)
                            .fontWeight(.medium)
                            .foregroundStyle(prefs.isEnabled(known) ? .primary : .secondary)
                        Text(credential.sourceName == ProvidersStore.manualSourceName
                             ? "手动配置" : "← \(credential.sourceName)")
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
                Text("只勾选的供应商会参与查询、小组件与状态栏；「连未选中的也查询」打开时会照常请求但不在界面展示。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
            prefs = DisplayStore.load()
            let fetched = await QueryService.fetchAll(fresh.filter { prefs.shouldQuery($0.kind) })
            if !fetched.isEmpty { SnapshotCache.save(fetched) }
            results = fetched
            fromCache = false
            running = false
            StatusBarController.shared.update(fetched)
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
                    // 余额型套餐（CommandCode 的 credits 池等）：把剩余额度单独提一行，比只给百分比直观
                    if usage.balance != nil || usage.paidBalance != nil {
                        HStack(spacing: 6) {
                            Image(systemName: "creditcard.fill")
                                .font(.caption2)
                                .foregroundStyle(usage.kind.brandColor)
                            // 套餐月度额度与额外充值的付费额度分开写，避免看成同一个池
                            Text(usage.paidBalanceText != nil
                                 ? "套餐剩余 \(usage.balanceText ?? "—") · \(usage.paidBalanceText ?? "")"
                                 : "剩余额度 \(usage.balanceText ?? "")")
                                .font(.caption.weight(.medium))
                                .monospacedDigit()
                            Spacer()
                            Text("更新 " + usage.timeCaption)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
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
