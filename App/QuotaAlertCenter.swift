import SwiftUI
import UserNotifications
import ServiceManagement
import WidgetKit

/// 警戒配置（存于 App Group 容器 alerts.json）
struct AlertConfig: Codable {
    var enabled = false
    /// 火山 / 智谱：任一窗口使用率 ≥ 阈值（%）时通知
    var volcThreshold: Double = 80
    var zhipuThreshold: Double = 80
    /// DeepSeek：余额 ≤ 阈值（元）时通知
    var deepseekThreshold: Double = 5
    var intervalMinutes: Int = 15
    /// 上次观察到的值，用于判断"跨越阈值"，避免重复通知
    var lastValues: [String: Double] = [:]
}

/// 定时查询三家用量并按阈值发本地通知。小组件扩展无法发通知，
/// 因此由 App 负责：启动后延迟检查一次，运行期间按间隔轮询。
@MainActor
final class QuotaAlertCenter: ObservableObject {
    static let shared = QuotaAlertCenter()
    static var fileURL: URL { AppGroup.dataDirectory.appendingPathComponent("alerts.json") }

    @Published var config: AlertConfig { didSet { persist() } }
    @Published var checking = false
    @Published var lastCheckText = ""
    @Published var authorizationDenied = false

    private var timer: Timer?
    private var started = false
    private let presenter = ForegroundPresenter()

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? JSONDecoder().decode(AlertConfig.self, from: data) {
            config = saved
        } else {
            config = AlertConfig()
        }
        UNUserNotificationCenter.current().delegate = presenter
    }

    func start() {
        guard !started else { return }
        started = true
        rescheduleTimer()
        if config.enabled {
            Task {
                try? await Task.sleep(for: .seconds(5))
                await checkNow()
            }
        }
    }

    func setEnabled(_ on: Bool) async {
        if on {
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            authorizationDenied = !granted
        }
        config.enabled = on
        rescheduleTimer()
        if on { await checkNow() }
    }

    func setInterval(_ minutes: Int) {
        config.intervalMinutes = minutes
        rescheduleTimer()
    }

    var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        objectWillChange.send()
    }

    /// 查询一次并评估阈值；结果同时写入快照供小组件与「用量」页复用
    func checkNow() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }

        let credentials = ProvidersStore.loadCredentials()
        guard !credentials.isEmpty else {
            lastCheckText = "未识别到任何凭据，请先在 cc-switch 或上方手动配置"
            return
        }
        let results = await QueryService.fetchAll(credentials)
        if !results.isEmpty {
            SnapshotCache.save(results)
            WidgetCenter.shared.reloadAllTimelines()
        }
        let alerts = evaluate(results)
        let failed = results.filter { !$0.ok }.map { $0.kind.displayName }
        var text = Self.clock() + " 检查完成"
        if !failed.isEmpty { text += "（\(failed.joined(separator: "、")) 查询失败）" }
        if alerts.isEmpty {
            text += "，未超阈值"
        } else if config.enabled {
            for alert in alerts { await post(alert) }
            text += "，已发送 \(alerts.count) 条通知"
        } else {
            text += "，\(alerts.count) 项超阈值（通知未启用）"
        }
        lastCheckText = text
    }

    // MARK: - 私有

    private struct Alert {
        var title: String
        var body: String
    }

    /// 从低于阈值跨到高于阈值（或首次观察即超标）才触发；窗口重置回落后再次超标会再次提醒
    private func evaluate(_ usages: [ProviderUsage]) -> [Alert] {
        var alerts: [Alert] = []
        for usage in usages where usage.ok {
            switch usage.kind {
            case .volcengine, .zhipu:
                let threshold = usage.kind == .volcengine ? config.volcThreshold : config.zhipuThreshold
                for window in usage.windowsInDisplayOrder {
                    let key = "\(usage.kind.rawValue).\(window.name)"
                    let previous = config.lastValues[key]
                    config.lastValues[key] = window.percent
                    if (previous ?? 0) < threshold, window.percent >= threshold {
                        alerts.append(Alert(
                            title: "\(usage.kind.displayName)「\(window.name)」已用 \(window.percent.percentText)",
                            body: "超过警戒线 \(Int(threshold))% · \(window.remainingText) · \(window.resetCaption)"))
                    }
                }
            case .deepseek:
                guard let balance = usage.balance else { continue }
                let key = "deepseek.balance"
                let previous = config.lastValues[key]
                config.lastValues[key] = balance
                if (previous ?? .greatestFiniteMagnitude) > config.deepseekThreshold, balance <= config.deepseekThreshold {
                    alerts.append(Alert(
                        title: "DeepSeek 余额仅剩 \(usage.balanceText ?? balance.money2)",
                        body: "低于警戒线 ¥\(config.deepseekThreshold.money2)，请及时充值"))
                }
            }
        }
        return alerts
    }

    private func post(_ alert: Alert) async {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func rescheduleTimer() {
        timer?.invalidate()
        timer = nil
        guard config.enabled else { return }
        let interval = TimeInterval(max(5, config.intervalMinutes) * 60)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in await QuotaAlertCenter.shared.checkNow() }
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    private static func clock() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date())
    }
}

/// App 在前台时也把通知以横幅展示
private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
