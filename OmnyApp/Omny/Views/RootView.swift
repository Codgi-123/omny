import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var dida: DidaService
    @Query(filter: #Predicate<InboxItem> { $0.needsReview && !$0.deletedLocally })
    private var reviewItems: [InboxItem]

    var body: some View {
        TabView {
            NavigationStack { TodayView() }
                .tabItem { Label("今天", systemImage: "house") }
            NavigationStack { ExpressView() }
                .tabItem { Label("快递", systemImage: "shippingbox") }
            NavigationStack { TripView() }
                .tabItem { Label("行程", systemImage: "tram") }
            NavigationStack { TodoView() }
                .tabItem { Label("待办", systemImage: "checkmark.circle") }
                .badge(reviewItems.filter { $0.kind == .todo }.count)
            NavigationStack { BookmarkView() }
                .tabItem { Label("收藏", systemImage: "bookmark") }
        }
        .tint(Theme.accent)
        .task {
            // 启动时先收分享队列，再后台同步一次滴答
            await drainShareQueue()
            await dida.syncNow(context: context)
        }
        .onChange(of: scenePhase) { _, phase in
            // 从后台回到前台时自动同步（带防抖，避免频繁切换反复拉取）
            guard phase == .active else { return }
            Task {
                await drainShareQueue()
                await dida.syncOnForeground(context: context)
            }
        }
    }

    /// 收走分享扩展排队的内容：落成收藏 + LLM 打标
    private func drainShareQueue() async {
        for shared in SharedInbox.drain() {
            await Ingestor.ingestBookmark(text: shared.text, urlString: shared.urlString,
                                          source: .share, context: context)
        }
    }
}

/// 导航栏右侧：需修正入口 + 设置入口
struct NavActions: View {
    @Query(filter: #Predicate<InboxItem> { $0.needsReview && !$0.deletedLocally })
    private var reviewItems: [InboxItem]

    var body: some View {
        HStack(spacing: 8) {
            if !reviewItems.isEmpty {
                NavigationLink {
                    ReviewView()
                } label: {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(Theme.accent)
                }
            }
            NavigationLink {
                SettingsView()
            } label: {
                Image(systemName: "gearshape")
                    .foregroundStyle(Theme.sub)
            }
        }
    }
}
