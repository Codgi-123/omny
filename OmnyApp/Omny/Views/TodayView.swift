import SwiftUI
import SwiftData

/// 聚合首页：行程横滑 → 快递横滑 → 今日待办 → 需处理
struct TodayView: View {
    @Query(sort: \InboxItem.createdAt, order: .reverse) private var items: [InboxItem]

    private var upcomingTrips: [InboxItem] {
        items.filter { $0.kind == .trip && ($0.departAt ?? .distantPast) > .now }
            .sorted { ($0.departAt ?? .distantFuture) < ($1.departAt ?? .distantFuture) }
    }

    private var awaitingPackages: [InboxItem] {
        items.filter { $0.kind == .package && $0.packageStatus != .pickedUp }
    }

    private var openTodos: [InboxItem] {
        items.filter { $0.kind == .todo && !$0.todoCompleted && !$0.needsReview && !$0.deletedLocally }
    }

    private var reviewItems: [InboxItem] {
        items.filter { $0.needsReview && !$0.deletedLocally }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10, pinnedViews: []) {
                if !upcomingTrips.isEmpty {
                    SectionHeader(icon: "tram", iconColor: Theme.slate, title: "行程",
                                  count: "\(upcomingTrips.count) 个即将出行")
                    horizontalCards(upcomingTrips) { TripCard(item: $0) }
                }

                if !awaitingPackages.isEmpty {
                    SectionHeader(icon: "shippingbox", iconColor: Theme.accent, title: "快递",
                                  count: "\(awaitingPackages.filter { $0.packageStatus == .awaitingPickup }.count) 件待取")
                    horizontalCards(awaitingPackages) { PackageCard(item: $0) }
                }

                if !openTodos.isEmpty {
                    SectionHeader(icon: "checkmark.circle", iconColor: Theme.green, title: "待办",
                                  count: "\(openTodos.count) 项未完成")
                    ForEach(openTodos.prefix(5)) { TodoRow(item: $0) }
                }

                if !reviewItems.isEmpty {
                    Text("需处理")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(Theme.sub)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .padding(.top, 14)
                    NavigationLink {
                        ReviewView()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(reviewItems.count) 条内容需要确认")
                                    .font(.system(size: 14.5, weight: .bold))
                                    .foregroundStyle(Theme.text)
                                Text("识别置信度低或需要勾选入库")
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(Theme.sub)
                            }
                            Spacer()
                            Badge(text: "需修正", color: Theme.accent)
                        }
                        .cardStyle()
                    }
                }

                if upcomingTrips.isEmpty && awaitingPackages.isEmpty && openTodos.isEmpty && reviewItems.isEmpty {
                    emptyState
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Theme.screen)
        .navigationTitle("今天")
        .toolbar { NavActions() }
    }

    private func horizontalCards<Content: View>(_ items: [InboxItem],
                                                @ViewBuilder content: @escaping (InboxItem) -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(items) { content($0).containerRelativeFrame(.horizontal) { w, _ in w * 0.88 } }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 36))
                .foregroundStyle(Theme.sub.opacity(0.7))
            Text("一切都处理完了")
                .font(.system(size: 15, weight: .bold))
            Text("短信、截图、分享进来的信息会出现在这里")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.sub)
        }
        .padding(.top, 100)
    }
}
