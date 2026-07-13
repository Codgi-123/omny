import SwiftUI
import SwiftData

/// 聚合首页：行程横滑 → 快递横滑 → 今日待办 → 需处理。
/// 自定义仪表盘（非分组表），所有内容统一到 16pt 左边距网格，保证轮播卡与待办卡左对齐。
struct TodayView: View {
    @Query(sort: \InboxItem.createdAt, order: .reverse) private var items: [InboxItem]
    /// 与 RootView 的 TabView selection 共享同一 UserDefaults 键：各区块「查看详情」写入即切 tab。
    @AppStorage("omnySelectedTab") private var selectedTab = 0

    private let margin: CGFloat = Theme.Space.page

    // 行程/快递轮播的顺序与列表页一致：手动拖过的按 sortOrder，没拖过按各自默认规则

    private var upcomingTrips: [InboxItem] {
        items.filter { $0.kind == .trip && $0.deletedAt == nil && ($0.departAt ?? .distantPast) > .now }
            .manuallySorted { ($0.departAt ?? .distantFuture) < ($1.departAt ?? .distantFuture) }
    }

    private var awaitingPackages: [InboxItem] {
        let open = items.filter { $0.kind == .package && $0.deletedAt == nil && $0.packageStatus != .pickedUp }
        // 待取排在在途前（对齐快递页的分组次序），组内各按手动顺序
        return open.filter { $0.packageStatus == .awaitingPickup }
            .manuallySorted { $0.createdAt > $1.createdAt }
            + open.filter { $0.packageStatus != .awaitingPickup }
            .manuallySorted { $0.createdAt > $1.createdAt }
    }

    private var openTodos: [InboxItem] {
        items.filter { $0.kind == .todo && !$0.todoCompleted && !$0.todoAbandoned && !$0.needsReview && !$0.deletedLocally && $0.deletedAt == nil }
            // 优先级降序（高→无），同级按创建时间倒序
            .sorted { ($0.todoPriority, $0.createdAt) > ($1.todoPriority, $1.createdAt) }
    }

    private var reviewItems: [InboxItem] {
        items.filter { $0.needsReview && !$0.deletedLocally && $0.deletedAt == nil }
    }

    /// 今天新增的收藏（未删除），首页「今日收藏」区块用
    private var todayBookmarks: [InboxItem] {
        items.filter { $0.kind == .bookmark && $0.deletedAt == nil
            && Calendar.current.isDateInToday($0.createdAt) }
    }

    private var everythingEmpty: Bool {
        upcomingTrips.isEmpty && awaitingPackages.isEmpty && openTodos.isEmpty
            && todayBookmarks.isEmpty && reviewItems.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader("今天") { NavActions() }
            ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !upcomingTrips.isEmpty {
                    // 只有一个行程时卡片占满内容区（无 peek/指示器）；两个及以上留出后卡的 peek。
                    let single = upcomingTrips.count == 1
                    CarouselSection(icon: "airplane.departure", tint: Theme.trip, title: "行程",
                                    count: "\(upcomingTrips.count) 个即将出行", items: upcomingTrips, margin: margin,
                                    widthFraction: single ? 1.0 : 0.82,
                                    onDetail: { selectedTab = 2 }) {
                        TripCard(item: $0).cardStyle()
                    }
                }

                if !awaitingPackages.isEmpty {
                    // 卡片数量自适应：1 件→大卡占满、无进度条；2 件→两张小卡、无进度条；≥3→紧凑小卡 + 进度条
                    let n = awaitingPackages.count
                    CarouselSection(icon: "shippingbox.fill", tint: Theme.express, title: "快递",
                                    count: "\(awaitingPackages.filter { $0.packageStatus == .awaitingPickup }.count) 件待取",
                                    items: awaitingPackages, margin: margin,
                                    widthFraction: n == 1 ? 1.0 : (n == 2 ? 0.5 : 0.44),
                                    barIndicator: n >= 3,
                                    onDetail: { selectedTab = 1 }) {
                        if n == 1 {
                            PackageCard(item: $0, showsContextMenu: false).cardStyle()
                        } else {
                            PackageCardCompact(item: $0).cardStyle()
                        }
                    }
                }

                if !openTodos.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(icon: "checkmark.circle.fill", tint: Theme.todo, title: "待办",
                                      count: "\(openTodos.count) 项未完成",
                                      onDetail: { selectedTab = 3 })
                        // 待办整体合并为一张卡片，条目列在卡内、以分隔线区隔（一.8）
                        let homeTodos = Array(openTodos.prefix(5))
                        VStack(spacing: 0) {
                            ForEach(Array(homeTodos.enumerated()), id: \.element.id) { idx, todo in
                                TodoRow(item: todo, showsContextMenu: false)
                                    .padding(.vertical, 11)
                                if idx < homeTodos.count - 1 {
                                    Divider().padding(.leading, 44)
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .background(Theme.card, in: .rect(cornerRadius: 12))
                        .shadow(color: .black.opacity(0.05), radius: 5, y: 2)
                    }
                    .padding(.horizontal, margin)
                }

                if !todayBookmarks.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(icon: "bookmark.fill", tint: Theme.bookmark, title: "今日收藏",
                                      count: "\(todayBookmarks.count) 条",
                                      onDetail: { selectedTab = 4 })
                        VStack(spacing: 10) {
                            ForEach(todayBookmarks.prefix(5)) { TodayBookmarkRow(item: $0).cardStyle(pad: 11) }
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

/// 首页「今日收藏」精简卡：缩略图/类型图标 + 标题 + 域名或标签。
/// 完整交互（打开/编辑/删标签）留在收藏页的 BookmarkCard，这里只做一眼概览。
private struct TodayBookmarkRow: View {
    let item: InboxItem

    private var url: URL? { item.urlString.flatMap(URL.init(string:)) }

    private var title: String {
        if let t = item.bookmarkTitle, !t.isEmpty { return t }
        if let url { return url.host() ?? "链接" }
        return item.rawText.components(separatedBy: .newlines).first ?? item.rawText
    }

    var body: some View {
        HStack(spacing: 12) {
            if let data = item.sourceImage, let ui = UIImage(data: data) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 36, height: 36)
                    .clipShape(.rect(cornerRadius: 9))
            } else {
                IconChip(symbol: url != nil ? "link" : "text.alignleft", color: Theme.bookmark, size: 36)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if let url {
                    Text(url.host() ?? url.absoluteString)
                        .font(.caption2)
                        .foregroundStyle(Theme.sub)
                        .lineLimit(1)
                } else if item.tags.isEmpty {
                    Text("未打标")
                        .font(.caption2)
                        .foregroundStyle(Theme.sub.opacity(0.7))
                } else {
                    HStack(spacing: 6) {
                        ForEach(item.tags.prefix(3), id: \.self) { Badge(text: "#\($0)", color: Theme.green) }
                    }
                }
            }
            Spacer(minLength: 0)
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
    var onDetail: (() -> Void)? = nil     // 非 nil 时区头行尾出现「查看详情」跳转
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
            SectionHeader(icon: icon, tint: tint, title: title, count: count, onDetail: onDetail)
                .padding(.horizontal, margin)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.gap) {
                    ForEach(items) {
                        content($0)
                            // 宽度按内容区（去掉左右 margin 与可视卡间距）折算，
                            // 否则整宽/半宽卡会超出屏幕右缘、贴边无间距。
                            .containerRelativeFrame(.horizontal) { w, _ in
                                let cols = CGFloat(visibleCount)
                                return (w - margin * 2 - Theme.Space.gap * (cols - 1)) * widthFraction
                            }
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
