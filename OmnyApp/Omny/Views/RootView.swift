import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var context
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
            // 启动时后台同步一次滴答
            await dida.syncNow(context: context)
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
