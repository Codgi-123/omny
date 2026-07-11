import SwiftUI
import SwiftData

/// 聚合首页：行程横滑 → 快递横滑 → 今日待办 → 需处理。
/// 自定义仪表盘（非分组表），所有内容统一到 16pt 左边距网格，保证轮播卡与待办卡左对齐。
struct TodayView: View {
    @Query(sort: \InboxItem.createdAt, order: .reverse) private var items: [InboxItem]

    private let margin: CGFloat = Theme.Space.page

    private var upcomingTrips: [InboxItem] {
        items.filter { $0.kind == .trip && $0.deletedAt == nil && ($0.departAt ?? .distantPast) > .now }
            .sorted { ($0.departAt ?? .distantFuture) < ($1.departAt ?? .distantFuture) }
    }

    private var awaitingPackages: [InboxItem] {
        items.filter { $0.kind == .package && $0.deletedAt == nil && $0.packageStatus != .pickedUp }
    }

    private var openTodos: [InboxItem] {
        items.filter { $0.kind == .todo && !$0.todoCompleted && !$0.needsReview && !$0.deletedLocally && $0.deletedAt == nil }
            // 优先级降序（高→无），同级按创建时间倒序
            .sorted { ($0.todoPriority, $0.createdAt) > ($1.todoPriority, $1.createdAt) }
    }

    private var reviewItems: [InboxItem] {
        items.filter { $0.needsReview && !$0.deletedLocally && $0.deletedAt == nil }
    }

    private var everythingEmpty: Bool {
        upcomingTrips.isEmpty && awaitingPackages.isEmpty && openTodos.isEmpty && reviewItems.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader("今天") { NavActions() }
            ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !upcomingTrips.isEmpty {
                    CarouselSection(icon: "tram.fill", tint: Theme.trip, title: "行程",
                                    count: "\(upcomingTrips.count) 个即将出行", items: upcomingTrips, margin: margin) {
                        TripCard(item: $0).cardStyle()
                    }
                }

                if !awaitingPackages.isEmpty {
                    CarouselSection(icon: "shippingbox.fill", tint: Theme.express, title: "快递",
                                    count: "\(awaitingPackages.filter { $0.packageStatus == .awaitingPickup }.count) 件待取",
                                    items: awaitingPackages, margin: margin, widthFraction: 0.44,
                                    barIndicator: true) {
                        PackageCardCompact(item: $0).cardStyle()
                    }
                }

                if !openTodos.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(icon: "checkmark.circle.fill", tint: Theme.todo, title: "待办",
                                      count: "\(openTodos.count) 项未完成")
                        VStack(spacing: 10) {
                            ForEach(openTodos.prefix(5)) { TodoRow(item: $0, showsContextMenu: false).cardStyle(pad: 11) }
                        }
                    }
                    .padding(.horizontal, margin)
                }

                if !reviewItems.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(icon: "exclamationmark.circle.fill", tint: Theme.accent, title: "需处理")
                        NavigationLink {
                            ReviewView()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(reviewItems.count) 条内容需要确认")
                                        .font(.body)
                                        .foregroundStyle(Theme.text)
                                    Text("识别置信度低或需要勾选入库")
                                        .font(.caption)
                                        .foregroundStyle(Theme.sub)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.footnote)
                                    .foregroundStyle(Theme.sub)
                            }
                            .cardStyle()
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, margin)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 20)
            }
        }
        .background(Theme.screen)
        .overlay {
            if everythingEmpty { emptyState }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("一切都处理完了", systemImage: "tray")
        } description: {
            Text("短信、截图、分享进来的信息会出现在这里")
        }
    }
}

/// 带分类色标题的横滑轮播：标题对齐 16pt，卡片整宽左起 16pt、向右溢出可滑。
/// 底部带一条只读位置指示滑块，展示总数与当前前后位置（不可拖动）。
private struct CarouselSection<Content: View>: View {
    let icon: String
    let tint: Color
    let title: String
    let count: String
    let items: [InboxItem]
    let margin: CGFloat
    var widthFraction: CGFloat = 0.82
    var barIndicator: Bool = false        // true：底部位置指示强制用细长进度条
    @ViewBuilder let content: (InboxItem) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var currentID: InboxItem.ID?

    private var currentIndex: Int {
        guard let currentID, let i = items.firstIndex(where: { $0.id == currentID }) else { return 0 }
        return i
    }
    /// 一屏能放下几张卡（由卡片宽度占比推算）
    private var visibleCount: Int { max(1, Int((1 / widthFraction).rounded(.down))) }
    /// 实际可滚动的"页数"：多卡可视时，最左卡片只能翻到 count-visibleCount，据此折算
    private var pageCount: Int { max(items.count - visibleCount + 1, 1) }
    /// 当前页（最左卡片序号夹到有效页范围内 → 滑到底就是最后一页）
    private var activePage: Int { min(max(currentIndex, 0), pageCount - 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(icon: icon, tint: tint, title: title, count: count)
                .padding(.horizontal, margin)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.gap) {
                    ForEach(items) {
                        content($0)
                            .containerRelativeFrame(.horizontal) { w, _ in w * widthFraction }
                            // 卡片移除时渐隐缩小，右侧后续卡片平滑补位；
                            // 减弱动效时只保留淡入淡出、去掉缩放位移。
                            .transition(reduceMotion ? .opacity
                                        : .scale(scale: 0.9).combined(with: .opacity))
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, margin)
                .padding(.vertical, 8)   // 给卡片阴影留出不被裁切的空间
                // 绑定 id 列表：条目增减（如快递标记已取移出）时触发过渡动画
                .animation(.snappy(duration: 0.3), value: items.map(\.persistentModelID))
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $currentID)

            // 只读位置指示：按实际页数展示（多卡可视时也能翻到最后一页）
            if pageCount > 1 {
                CarouselIndicator(count: pageCount, index: activePage,
                                  tint: tint, forceBar: barIndicator)
                    .padding(.horizontal, margin)
            }
        }
    }
}

/// 只读轮播位置指示：自适应。≤6 张用经典小圆点（符合 HIG）；更多时换成一段细比例滑块
/// （宽度随总数变短，暗示数量；位置随当前卡片移动）。纯展示、不可交互。
private struct CarouselIndicator: View {
    let count: Int
    let index: Int
    var tint: Color = Theme.express
    var forceBar: Bool = false        // 强制用进度条（紧凑多卡轮播用）

    private let dotThreshold = 6

    var body: some View {
        Group {
            if count <= dotThreshold && !forceBar { dots } else { bar }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.25), value: index)
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(i == index ? tint : Theme.line.opacity(0.4))
                    .frame(width: 6, height: 6)
            }
        }
    }

    private var bar: some View {
        GeometryReader { geo in
            let track = geo.size.width
            let thumb = max(track / CGFloat(count), 20)
            let maxX = max(track - thumb, 0)
            let x = count > 1 ? maxX * CGFloat(index) / CGFloat(count - 1) : 0
            Capsule()
                .fill(Theme.line.opacity(0.3))
                .overlay(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.9)).frame(width: thumb).offset(x: x)
                }
        }
        .frame(height: 3)
    }
}
