import SwiftUI
import SwiftData

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

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(AppSettings.shared)
                .environmentObject(DidaService.shared)
        }
        .modelContainer(Self.sharedModelContainer)
    }
}
