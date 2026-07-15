import SwiftUI
import SwiftData
import UserNotifications

@main
struct OmnyApp: App {
    /// App Intents 也要访问，做成静态共享容器
    static let sharedModelContainer: ModelContainer = {
        do {
            return try ModelContainer(for: InboxItem.self)
        } catch {
            fatalError("无法创建数据库: \(error)")
        }
    }()

    init() {
        // 前台也弹通知横幅（无 delegate 时 App 在前台收不到任何提示）
        UNUserNotificationCenter.current().delegate = NotificationScheduler.foregroundDelegate
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(AppSettings.shared)
                .environmentObject(DidaService.shared)
        }
        .modelContainer(Self.sharedModelContainer)
    }
}
