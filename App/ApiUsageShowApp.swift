import SwiftUI
import WidgetKit

@main
struct ApiUsageShowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("API Usage 小组件") {
            TabView {
                StatusView()
                    .tabItem { Label("用量", systemImage: "gauge.with.dots.needle.33percent") }
                ModelsView()
                    .tabItem { Label("模型", systemImage: "cpu") }
                SettingsView()
                    .tabItem { Label("设置", systemImage: "gearshape") }
            }
            .frame(minWidth: 620, idealWidth: 660, minHeight: 620, idealHeight: 720)
        }
        .defaultSize(width: 660, height: 720)
    }
}

/// 状态栏由 AppDelegate 管理（SwiftUI App 生命周期里没有 NSStatusItem 的天然挂点）
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            // 状态栏常驻：图标 + 主窗口百分比，点开是每家明细
            StatusBarController.shared.start()
            StatusBarController.shared.refreshAction = {
                let credentials = ProvidersStore.loadCredentials()
                let prefs = DisplayStore.load()
                let targets = credentials.filter { prefs.shouldQuery($0.kind) }
                guard !targets.isEmpty else { return }
                let results = await QueryService.fetchAll(targets)
                if !results.isEmpty {
                    SnapshotCache.save(results)
                    StatusBarController.shared.update(results)
                    WidgetCenter.shared.reloadAllTimelines()
                }
            }
            NotificationCenter.default.addObserver(
                forName: .statusBarShouldRefresh, object: nil, queue: .main) { _ in
                    Task { @MainActor in StatusBarController.shared.reloadFromCache() }
                }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false   // 关窗不退出，状态栏继续常驻
    }
}
