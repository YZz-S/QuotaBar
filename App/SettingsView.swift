import SwiftUI
import WidgetKit

extension Notification.Name {
    /// 设置页保存了手动凭据，「用量」页据此重新识别
    static let credentialsChanged = Notification.Name("ApiUsageShow.credentialsChanged")
}

/// 「设置」页：手动填写 API Key（覆盖 cc-switch 自动识别）+ 警戒通知
struct SettingsView: View {
    @ObservedObject private var alerts = QuotaAlertCenter.shared

    @State private var volcAccessKey = ""
    @State private var volcSecretKey = ""
    @State private var volcRegion = ""
    @State private var zhipuApiKey = ""
    @State private var zhipuBaseUrl = ""
    @State private var deepseekToken = ""
    @State private var effective: [ProviderCredentials] = []
    @State private var saveMessage = ""
    @State private var launchAtLogin = false
    @State private var launchError = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape")
                        .font(.title2)
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("设置").font(.headline)
                        Text("手动填写的 Key 优先于 cc-switch 自动识别；留空即沿用自动识别")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                credentialsSection
                notificationSection
            }
            .padding(18)
        }
        .onAppear {
            loadManualFields()
            refreshEffective()
            launchAtLogin = alerts.launchAtLogin
            alerts.start()
        }
    }

    // MARK: - 手动凭据

    private var credentialsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                providerForm(.volcengine) {
                    TextField("Access Key ID（火山引擎 IAM 的 AK，不是推理 API Key）", text: $volcAccessKey)
                    SecureField("Secret Access Key", text: $volcSecretKey)
                    TextField("Region（留空默认 cn-beijing）", text: $volcRegion)
                }
                Divider()
                providerForm(.zhipu) {
                    SecureField("API Key（id.secret 格式）", text: $zhipuApiKey)
                    TextField("用量接口地址（留空默认 open.bigmodel.cn/api/monitor/usage/quota/limit）", text: $zhipuBaseUrl)
                }
                Divider()
                providerForm(.deepseek) {
                    SecureField("API Key（sk-…）", text: $deepseekToken)
                }
                HStack(spacing: 10) {
                    Button("保存手动配置") { saveManual() }
                        .buttonStyle(.borderedProminent)
                    Button("清空全部手动配置") { clearManual() }
                    Text(saveMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Text("保存后写入 App Group 容器（仅本用户可读），小组件与通知检查同步生效。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("API Key 手动配置", systemImage: "key.fill")
                .font(.subheadline.weight(.semibold))
        }
        .textFieldStyle(.roundedBorder)
    }

    private func providerForm<Content: View>(_ kind: ProviderKind, @ViewBuilder fields: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: kind.iconSymbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(kind.brandColor)
                    .frame(width: 22, height: 22)
                    .background(kind.brandColor.opacity(0.14), in: Circle())
                Text(kind.displayName).fontWeight(.medium)
                Spacer()
                Text(sourceCaption(kind))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            fields()
                .font(.caption)
        }
    }

    private func sourceCaption(_ kind: ProviderKind) -> String {
        guard let credential = effective.first(where: { $0.kind == kind }) else { return "当前：未配置" }
        return credential.sourceName == ProvidersStore.manualSourceName
            ? "当前：手动配置"
            : "当前：cc-switch「\(credential.sourceName)」"
    }

    private func loadManualFields() {
        for manual in ProvidersStore.loadManual() {
            switch manual.kind {
            case .volcengine:
                volcAccessKey = manual.accessKey ?? ""
                volcSecretKey = manual.secretKey ?? ""
                volcRegion = manual.region ?? ""
            case .zhipu:
                zhipuApiKey = manual.apiKey ?? ""
                zhipuBaseUrl = manual.baseUrl ?? ""
            case .deepseek:
                deepseekToken = manual.bearerToken ?? ""
            }
        }
    }

    private func refreshEffective() {
        effective = ProvidersStore.loadCredentials()
    }

    private func saveManual() {
        var list: [ProviderCredentials] = []
        let ak = volcAccessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let sk = volcSecretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ak.isEmpty, !sk.isEmpty {
            let region = volcRegion.trimmingCharacters(in: .whitespacesAndNewlines)
            list.append(ProviderCredentials(kind: .volcengine, sourceName: ProvidersStore.manualSourceName,
                                            accessKey: ak, secretKey: sk,
                                            region: region.isEmpty ? "cn-beijing" : region))
        }
        let apiKey = zhipuApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !apiKey.isEmpty {
            let baseUrl = zhipuBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            list.append(ProviderCredentials(kind: .zhipu, sourceName: ProvidersStore.manualSourceName,
                                            apiKey: apiKey, baseUrl: baseUrl.isEmpty ? nil : baseUrl))
        }
        let token = deepseekToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            list.append(ProviderCredentials(kind: .deepseek, sourceName: ProvidersStore.manualSourceName,
                                            bearerToken: token))
        }
        ProvidersStore.saveManual(list)
        applyAndNotify()
        saveMessage = list.isEmpty ? "已清空，沿用 cc-switch 自动识别" : "已保存 \(list.count) 项手动配置"
    }

    private func clearManual() {
        volcAccessKey = ""; volcSecretKey = ""; volcRegion = ""
        zhipuApiKey = ""; zhipuBaseUrl = ""
        deepseekToken = ""
        ProvidersStore.saveManual([])
        applyAndNotify()
        saveMessage = "已清空，沿用 cc-switch 自动识别"
    }

    private func applyAndNotify() {
        let merged = ProvidersStore.loadCredentials()
        ProvidersStore.exportCredentials(merged)
        effective = merged
        WidgetCenter.shared.reloadAllTimelines()
        NotificationCenter.default.post(name: .credentialsChanged, object: nil)
    }

    // MARK: - 警戒通知

    private var notificationSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: Binding(
                    get: { alerts.config.enabled },
                    set: { on in Task { await alerts.setEnabled(on) } }
                )) {
                    Text("启用警戒通知")
                        .fontWeight(.medium)
                }
                if alerts.authorizationDenied {
                    Label("系统未授权通知：请到 系统设置 → 通知 → API Usage 打开允许通知", systemImage: "bell.slash")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                thresholdSlider("火山方舟 任一窗口使用率 ≥", value: Binding(
                    get: { alerts.config.volcThreshold },
                    set: { alerts.config.volcThreshold = $0 }), color: ProviderKind.volcengine.brandColor)
                thresholdSlider("智谱 GLM 任一窗口使用率 ≥", value: Binding(
                    get: { alerts.config.zhipuThreshold },
                    set: { alerts.config.zhipuThreshold = $0 }), color: ProviderKind.zhipu.brandColor)

                HStack(spacing: 8) {
                    Image(systemName: ProviderKind.deepseek.iconSymbol)
                        .foregroundStyle(ProviderKind.deepseek.brandColor)
                        .frame(width: 18)
                    Text("DeepSeek 余额 ≤ ¥")
                    TextField("5", value: Binding(
                        get: { alerts.config.deepseekThreshold },
                        set: { alerts.config.deepseekThreshold = max(0, $0) }),
                              format: .number.precision(.fractionLength(0...2)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Spacer()
                }
                .font(.caption)

                HStack(spacing: 8) {
                    Text("检查间隔")
                    Picker("", selection: Binding(
                        get: { alerts.config.intervalMinutes },
                        set: { alerts.setInterval($0) })) {
                        Text("5 分钟").tag(5)
                        Text("15 分钟").tag(15)
                        Text("30 分钟").tag(30)
                        Text("60 分钟").tag(60)
                    }
                    .labelsHidden()
                    .frame(width: 110)
                    Button {
                        Task { await alerts.checkNow() }
                    } label: {
                        HStack(spacing: 4) {
                            if alerts.checking { ProgressView().controlSize(.mini) }
                            Text(alerts.checking ? "检查中…" : "立即检查")
                        }
                    }
                    .disabled(alerts.checking)
                    Text(alerts.lastCheckText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                }
                .font(.caption)

                Divider()

                Toggle(isOn: Binding(
                    get: { launchAtLogin },
                    set: { on in
                        do {
                            try alerts.setLaunchAtLogin(on)
                            launchAtLogin = on
                            launchError = ""
                        } catch {
                            launchError = error.localizedDescription
                        }
                    }
                )) {
                    Text("登录时自动启动（让检查在后台持续运行）")
                }
                if !launchError.isEmpty {
                    Text(launchError).font(.caption).foregroundStyle(.red)
                }
                Text("小组件扩展本身不能发通知，检查由本应用完成：启动后 5 秒查一次，之后按间隔轮询；关闭应用即停止。每个窗口只在从低于阈值跨到高于阈值时提醒一次，重置回落后再次超标会再提醒。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("警戒通知", systemImage: "bell.badge")
                .font(.subheadline.weight(.semibold))
        }
    }

    private func thresholdSlider(_ title: String, value: Binding<Double>, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title)
            Slider(value: value, in: 50...95, step: 5)
                .frame(maxWidth: 220)
            Text("\(Int(value.wrappedValue))%")
                .monospacedDigit()
                .frame(width: 36, alignment: .trailing)
            Spacer()
        }
        .font(.caption)
    }
}
