import SwiftUI
import WidgetKit

@main
struct ApiUsageShowApp: App {
    var body: some Scene {
        WindowGroup("API Usage 小组件") {
            TabView {
                StatusView()
                    .tabItem { Label("用量", systemImage: "gauge.with.dots.needle.33percent") }
                ModelsView()
                    .tabItem { Label("模型", systemImage: "cpu") }
            }
            .frame(minWidth: 620, idealWidth: 660, minHeight: 620, idealHeight: 720)
        }
        .defaultSize(width: 660, height: 720)
    }
}
