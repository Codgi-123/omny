import SwiftUI
import SwiftData
import PhotosUI
import OmnyCore

// MARK: - 拖动排序触感

/// 长按抬卡触感：List 原生拖动排序抬起时没有震动反馈，补一个中震。
/// 不能用 SwiftUI 手势——它与 List 底层 UIKit 拖拽互斥（长按设 0.5s 被系统取消收不到震动，
/// 设 0.25s 先完成又会抢掉系统拖拽导致拖不动）。改为行背景埋探针视图，向上找到 List 的
/// UICollectionView，直接监听系统抬卡（长按类）手势的 .began 时刻补震：
/// 不参与手势竞争，拖动不受影响，且与抬卡时机严格同步。
extension View {
    @ViewBuilder
    func dragLiftHaptic(_ enabled: Bool = true) -> some View {
        if enabled {
            background(ReorderLiftHaptic())
        } else {
            self
        }
    }
}

private struct ReorderLiftHaptic: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe {
        let v = Probe()
        v.isUserInteractionEnabled = false
        return v
    }
    func updateUIView(_ uiView: Probe, context: Context) {}

    final class Probe: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            var v = superview
            while let cur = v, !(cur is UICollectionView) { v = cur.superview }
            guard let cv = v as? UICollectionView else { return }
            // 抬卡由长按类手势驱动（_UIDragLift… 是 UILongPressGestureRecognizer 子类）；
            // 这两个列表的行没有长按菜单，不会误触发
            for g in cv.gestureRecognizers ?? [] where g is UILongPressGestureRecognizer {
                HapticRelay.hook(g)
            }
        }
    }

    /// addTarget 的接收者 + 按手势去重（行复用时探针会反复挂载，防止同一手势重复加 target 叠加震动）
    final class HapticRelay: NSObject {
        static let shared = HapticRelay()
        private static var hookedKey: UInt8 = 0

        static func hook(_ g: UIGestureRecognizer) {
            guard objc_getAssociatedObject(g, &hookedKey) == nil else { return }
            objc_setAssociatedObject(g, &hookedKey, true, .OBJC_ASSOCIATION_RETAIN)
            g.addTarget(shared, action: #selector(stateChanged(_:)))
        }

        @objc private func stateChanged(_ g: UIGestureRecognizer) {
            if g.state == .began {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        }
    }
}

/// 落位轻震：与抬卡的中震形成「拿起-放下」一对反馈
func dragDropHaptic() {
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
}

// MARK: - 快递列表：待取 / 在途 / 已签收（PackageTripView「快递」分段的内容，标题栏在容器层）

struct ExpressView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \InboxItem.createdAt, order: .reverse) private var items: [InboxItem]

    private var packages: [InboxItem] { items.active(.package) }
    // 待取/在途支持长按拖动排序（首页轮播同序）；默认（未拖过）按创建时间倒序
    private var awaiting: [InboxItem] {
        packages.filter { $0.packageStatus == .awaitingPickup }
            .manuallySorted { $0.createdAt > $1.createdAt }
    }
    private var inTransit: [InboxItem] {
        packages.filter { $0.packageStatus < .awaitingPickup }
            .manuallySorted { $0.createdAt > $1.createdAt }
    }

    @State private var pendingDelete: InboxItem?   // 待确认删除的快递（非 nil 时弹确认框）
    // 一键复制所有取件码的成功反馈：共享状态机，见 Views/Components/Feedback.swift
    @State private var copyFeedback = CopyFeedback()

    var body: some View {
        List {
            group("待取", awaiting, showsCopyAll: true, movable: true)
            group("在途", inTransit, movable: true)
            group("已签收", packages.filter { $0.packageStatus == .pickedUp }, dimmed: true)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.screen)
        .overlay {
            if packages.isEmpty {
                ContentUnavailableView("暂无快递", systemImage: "shippingbox",
                                       description: Text("驿站短信到达后会自动出现在这里"))
            }
        }
        // 删除确认 + 恢复指引：软删除可恢复，仍给一道确认，避免误删。居中 alert，比底部 sheet 更紧凑。
        .alert(
            "删除这件快递？",
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { pkg in
            Button("删除", role: .destructive) {
                withAnimation(.snappy) { Trash.softDelete(pkg, context: context) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("删除后会移到回收站，7 天内可在「设置 → 回收站」恢复，逾期自动清除。")
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ list: [InboxItem], dimmed: Bool = false,
                       showsCopyAll: Bool = false, movable: Bool = false) -> some View {
        if !list.isEmpty {
            Section {
                ForEach(list) { pkg in
                    PackageCard(item: pkg, showsContextMenu: false).opacity(dimmed ? 0.55 : 1).cardCell()
                        // 取件/撤销用卡片上的圆圈就地切换；这里只保留右滑删除。
                        // 右滑（leading）删除：关掉整滑触发，只露出红色按钮，点按后再弹确认。
                        // 按钮不设 role: .destructive —— 否则点击会立刻播放「行删除」动画，但此刻还没真删，
                        // 导致卡片闪出又弹回。红色由 .tint 提供，真正的删除动画留到 alert 确认后。
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            Button {
                                pendingDelete = pkg
                            } label: { Label("删除", systemImage: "trash") }
                                .tint(Theme.red)
                        }
                        .dragLiftHaptic(movable)
                }
                // 长按拖动排序（List 原生手势，无需编辑模式），落位后重写组内 sortOrder
                .onMove { from, to in
                    guard movable else { return }
                    list.applyManualMove(from: from, to: to)
                    try? context.save()
                    dragDropHaptic()
                }
                .moveDisabled(!movable)
            } header: {
                sectionHeader(title, count: list.count, copyAll: showsCopyAll ? list : nil)
            }
        }
    }

    /// 分区头：标题 + 计数；「待取」区额外带「一键复制所有取件码」按钮（有取件码时才显示）。
    @ViewBuilder
    private func sectionHeader(_ title: String, count: Int? = nil,
                              copyAll: [InboxItem]? = nil) -> some View {
        HStack(spacing: 8) {
            Text(count.map { "\(title) \($0)" } ?? title)
                .font(.subheadline).fontWeight(.semibold)
                .foregroundStyle(Theme.sub)
            Spacer()
            if let copyAll, copyAll.contains(where: { !($0.pickupCode ?? "").isEmpty }) {
                Button { copyAllCodes(copyAll) } label: {
                    HStack(spacing: 4) {
                        CopyGlyph(copied: copyFeedback.copied, size: 13)
                        Text(copyFeedback.copied ? "已复制" : "复制取件码")
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(copyFeedback.copied ? Theme.green : Theme.accent)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .sensoryFeedback(.success, trigger: copyFeedback.copied) { _, now in now }
            }
        }
        .textCase(nil)
    }

    /// 复制所有待取件的取件码：每行「驿站/公司 取件码」，可读性优先；复制后轻量成功反馈 1.5s 回退。
    private func copyAllCodes(_ list: [InboxItem]) {
        let lines = list.compactMap { item -> String? in
            guard let code = item.pickupCode, !code.isEmpty else { return nil }
            let place = [item.carrier, item.station].compactMap { $0 }.joined(separator: " ")
            return place.isEmpty ? code : "\(place) \(code)"
        }
        guard !lines.isEmpty else { return }
        copyFeedback.copy(lines.joined(separator: "\n"))
    }
}

// MARK: - 行程列表：即将出行 / 历史（PackageTripView「行程」分段的内容，标题栏在容器层）

struct TripView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \InboxItem.createdAt, order: .reverse) private var items: [InboxItem]

    private var trips: [InboxItem] { items.active(.trip) }

    /// 航班动态查询键（航班号|日期）集合，变化时触发 .task 补刷
    private var flightTaskID: [String] {
        trips.compactMap { FlightDynamicsStore.query(for: $0)?.key }.sorted()
    }

    /// 分组边界：车/机按出发时间；酒店按离店时间——入住期间（卡片显示「入住中」）仍留在上组
    private func tripEnd(_ item: InboxItem) -> Date {
        if item.tripKindRaw == "hotel" { return item.arriveAt ?? item.departAt ?? .distantPast }
        return item.departAt ?? .distantPast
    }

    /// 即将出行支持长按拖动排序（首页轮播同序）；默认（未拖过）按出发时间升序
    private var upcoming: [InboxItem] {
        trips.filter { tripEnd($0) > .now }
            .manuallySorted { ($0.departAt ?? .distantFuture) < ($1.departAt ?? .distantFuture) }
    }
    private var past: [InboxItem] {
        trips.filter { tripEnd($0) <= .now }
            .sorted { ($0.departAt ?? .distantPast) > ($1.departAt ?? .distantPast) }
    }

    var body: some View {
        List {
            if !upcoming.isEmpty {
                Section {
                    ForEach(upcoming) { item in
                        TripCard(item: item).cardCell()
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    withAnimation(.snappy) { Trash.softDelete(item, context: context) }
                                } label: { Label("删除", systemImage: "trash") }
                            }
                            .dragLiftHaptic()
                    }
                    // 长按拖动排序（List 原生手势，无需编辑模式），落位后重写组内 sortOrder
                    .onMove { from, to in
                        upcoming.applyManualMove(from: from, to: to)
                        try? context.save()
                        dragDropHaptic()
                    }
                } header: {
                    tripHeader("即将出行")
                }
            }
            if !past.isEmpty {
                Section {
                    ForEach(past) { item in
                        TripCard(item: item).opacity(0.6).cardCell()
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    withAnimation(.snappy) { Trash.softDelete(item, context: context) }
                                } label: { Label("删除", systemImage: "trash") }
                            }
                    }
                } header: {
                    tripHeader("历史行程")
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.screen)
        // 航班动态：下拉强刷无视缓存；页面出现/航班集合变化时只补过期的（10 分钟 TTL）。
        // 防取消原因见 Views/Components/RefreshableDetached.swift（同滴答同步的处理）。
        .refreshableDetached {
            await FlightDynamicsStore.shared.refresh(trips, force: true)
        }
        .task(id: flightTaskID) {
            await FlightDynamicsStore.shared.refresh(trips, force: false)
        }
        .overlay {
            if upcoming.isEmpty && past.isEmpty {
                ContentUnavailableView {
                    Label("暂无即将出行", systemImage: "tram")
                } description: {
                    Text("购票短信会自动生成行程卡片")
                }
            }
        }
    }

    private func tripHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline).fontWeight(.semibold)
            .foregroundStyle(Theme.sub)
            .textCase(nil)
    }
}

// MARK: - 待办页：同步横幅 + 待办 / 已完成

struct TodoView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var dida: DidaService
    @Query(sort: \InboxItem.createdAt, order: .reverse) private var items: [InboxItem]
    @State private var showAdd = false
    /// 已完成区默认收起，只留计数，减少长列表干扰
    @State private var showCompleted = false
    /// 已放弃区同样默认收起
    @State private var showAbandoned = false
    /// 收起的优先级组（存 rawValue）：默认全部展开，各组独立记忆
    @State private var collapsedPriorities: Set<Int> = []

    private var todos: [InboxItem] {
        items.activeTodos()
    }

    /// 未完成 = 未完成且未放弃
    private var openTodos: [InboxItem] { todos.filter { !$0.todoCompleted && !$0.todoAbandoned } }

    /// 组内排序：按截止时间倒序（晚的在前），无截止排在最后，再按创建时间倒序兜底。
    private func sortedByDue(_ list: [InboxItem]) -> [InboxItem] {
        list.sorted { a, b in
            switch (a.todoDue, b.todoDue) {
            case let (x?, y?): return x > y
            case (nil, _?):    return false
            case (_?, nil):    return true
            case (nil, nil):   return a.createdAt > b.createdAt
            }
        }
    }

    /// 优先级组内的一行：行样式对齐首页「今日待办」（TodoRow + 纵向 11pt、条目间无分隔线），
    /// 首/末行圆角、中间行直角，视觉上拼成一张整卡；行间 inset 归零使其无缝相接。
    private func priorityGroupRow(_ todo: InboxItem, isFirst: Bool, isLast: Bool) -> some View {
        let radius: CGFloat = 12
        return TodoRow(item: todo)
            .padding(.vertical, 11)
            .padding(.horizontal, 14)
            // 卡片底画在 listRowBackground 上：内容背景盖不满整个 cell（部分行会在边缘漏出
            // 一条屏幕底色的细缝），row 背景铺满 cell 才能无缝拼卡。水平缩进对齐卡片边缘，
            // 首/末行再缩回各自的 5pt 行间距。阴影没法整卡挂（行级阴影会在接缝渗灰线），不加。
            .listRowBackground(
                UnevenRoundedRectangle(topLeadingRadius: isFirst ? radius : 0,
                                       bottomLeadingRadius: isLast ? radius : 0,
                                       bottomTrailingRadius: isLast ? radius : 0,
                                       topTrailingRadius: isFirst ? radius : 0)
                    .fill(Theme.card)
                    .padding(.horizontal, Theme.Space.page)
                    .padding(.top, isFirst ? 5 : 0)
                    .padding(.bottom, isLast ? 5 : 0)
            )
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: isFirst ? 5 : 0, leading: Theme.Space.page,
                                      bottom: isLast ? 5 : 0, trailing: Theme.Space.page))
    }

    var body: some View {
        VStack(spacing: 0) {
            todoHeader
            List {
            let open = openTodos
            // 按优先级分组：高 → 中 → 低 → 无；组内按截止时间倒序
            ForEach([TodoPriority.high, .medium, .low, .none]) { p in
                let group = sortedByDue(open.filter { $0.todoPriority == p.rawValue })
                if !group.isEmpty {
                    let expanded = !collapsedPriorities.contains(p.rawValue)
                    Section {
                        // 组内行样式与首页「今日待办」一致：条目列在一张整卡内、以分隔线区隔；
                        // 每条仍是独立 List row（首/末行圆角拼卡），横滑删除/放弃按条生效
                        if expanded {
                            ForEach(Array(group.enumerated()), id: \.element.id) { idx, todo in
                                priorityGroupRow(todo, isFirst: idx == 0, isLast: idx == group.count - 1)
                            }
                        }
                    } header: {
                        // 折叠头部收编为共享组件（Views/Components/CollapsibleSectionHeader.swift）；
                        // 展开态存的是「收起集合」，用自定义 Binding 转换
                        CollapsibleSectionHeader(title: p.label, count: group.count, expanded: Binding(
                            get: { !collapsedPriorities.contains(p.rawValue) },
                            set: { open in
                                if open { collapsedPriorities.remove(p.rawValue) }
                                else { collapsedPriorities.insert(p.rawValue) }
                            }
                        )) {
                            Image(systemName: "flag.fill")
                                .font(.caption2)
                                .foregroundStyle(p.color)
                        }
                        .sectionHeaderInset()
                    }
                }
            }

            let done = todos.filter { $0.todoCompleted && !$0.todoAbandoned }
            if !done.isEmpty {
                Section {
                    if showCompleted {
                        ForEach(done) { TodoRow(item: $0).opacity(0.6).cardCell(pad: 8) }
                    }
                } header: {
                    CollapsibleSectionHeader(title: "已完成", count: done.count,
                                             expanded: $showCompleted)
                        .sectionHeaderInset()
                }
            }

            // 已放弃分组：参考「已完成」的收起交互；叉叉 + 划线 + 变灰由 TodoRow 呈现
            let abandoned = todos.filter(\.todoAbandoned)
            if !abandoned.isEmpty {
                Section {
                    if showAbandoned {
                        ForEach(abandoned) { TodoRow(item: $0).opacity(0.6).cardCell(pad: 8) }
                    }
                } header: {
                    CollapsibleSectionHeader(title: "已放弃", count: abandoned.count,
                                             expanded: $showAbandoned)
                        .sectionHeaderInset()
                }
            }
        }
            .listStyle(.plain)
            // 优先级组的行要无缝拼成整卡，清掉 List 的默认行距
            .listRowSpacing(0)
            .scrollContentBackground(.hidden)
            // 防取消原因见 Views/Components/RefreshableDetached.swift
            .refreshableDetached { await dida.syncNow(context: context) }
        }
        .background(Theme.screen)
        .overlay(alignment: .bottomTrailing) {
            if !showAdd { FloatingAddButton { showAdd = true } }
        }
        .overlay {
            if showAdd { TodoQuickAdd(isPresented: $showAdd) }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    /// 大标题 + 紧跟其下的同步状态行（刷新 icon 跟在上次同步时间后面）。
    private var todoHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center) {
                Text("待办").font(.largeTitle).fontWeight(.bold)
                Spacer()
                NavActions()
            }
            HStack(spacing: 6) {
                Circle()
                    .fill(settings.didaBound ? Theme.green : Theme.sub)
                    .frame(width: 6, height: 6)
                Text(syncLine)
                    .font(.caption)
                    .foregroundStyle(Theme.sub)
                    .lineLimit(1)
                if dida.syncing {
                    ProgressView().controlSize(.mini)
                } else if settings.didaBound {
                    Button { Task { await dida.syncNow(context: context) } } label: {
                        Image(systemName: "arrow.clockwise").font(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, Theme.Space.page)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private var syncLine: String {
        let head = settings.didaBound ? "滴答清单 · \(settings.didaProjectName ?? "")" : "本地模式"
        return head + " · " + bannerDetail
    }

    private var bannerDetail: String {
        if let error = dida.lastError { return error }
        if let last = settings.didaLastSync {
            return "上次同步 " + last.formatted(date: .omitted, time: .shortened)
        }
        return settings.didaBound ? "下拉触发同步" : "未绑定时功能照常可用"
    }
}

// MARK: - 收藏页：tag 筛选 + 链接/文本卡片 + 手动添加

struct BookmarkView: View {
    /// 筛选状态：全部 / 某个 tag / 未打标
    private enum TagFilter: Equatable {
        case all, tag(String), untagged
    }

    @Environment(\.modelContext) private var context
    @EnvironmentObject private var settings: AppSettings
    @Query(sort: \InboxItem.createdAt, order: .reverse) private var items: [InboxItem]
    @State private var filter: TagFilter = .all
    @State private var query = ""
    @State private var showAddSheet = false
    @State private var editingItem: InboxItem?
    @State private var detailItem: InboxItem?
    /// zoom 转场命名空间：列表行（源）与详情页（目的地）共用
    @Namespace private var zoomNS

    private var bookmarks: [InboxItem] { items.active(.bookmark) }

    private var filtered: [InboxItem] {
        let base: [InboxItem]
        switch filter {
        case .all: base = bookmarks
        case .tag(let tag): base = bookmarks.filter { $0.tags.contains(tag) }
        case .untagged: base = bookmarks.filter { $0.tags.isEmpty }
        }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return base }
        return base.filter { item in
            let hay = [item.bookmarkTitle, item.urlString, item.rawText]
                .compactMap { $0 }.joined(separator: " ").lowercased()
            return hay.contains(q) || item.tags.contains { $0.lowercased().contains(q) }
        }
    }

    /// 筛选栏展示的 tag：设置页的列表 + 存量条目上已有但被删掉的 tag
    private var visibleTags: [String] {
        settings.mergedTagCandidates(including: bookmarks.flatMap(\.tags))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader("收藏") { NavActions() }
            if !bookmarks.isEmpty { searchBar }
            List {
            if !bookmarks.isEmpty {
                tagFilterBar.carouselRow()
            }
            ForEach(filtered) { item in
                BookmarkCard(item: item,
                             onOpenDetail: { detailItem = item },
                             onEditTags: { editingItem = item },
                             onDelete: {
                                 withAnimation(.snappy) { Trash.softDelete(item, context: context) }
                             })
                    .cardCell()
                    // zoom 转场源标记：id 用 item.id 保证行级唯一；圆角对齐卡片，避免起飞瞬间直角
                    .matchedTransitionSource(id: item.id, in: zoomNS) {
                        $0.clipShape(.rect(cornerRadius: 12))
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.screen)
        .overlay {
            if bookmarks.isEmpty {
                ContentUnavailableView("暂无收藏", systemImage: "bookmark",
                                       description: Text("在任意 App 里点分享 → 选 Omny，链接、文字、图片都能收"))
            } else if filtered.isEmpty {
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ContentUnavailableView("该标签下暂无收藏", systemImage: "tag")
                }
            }
        }
        .sheet(isPresented: $showAddSheet) { BookmarkAddSheet() }
        .sheet(item: $editingItem) { item in
            BookmarkTagSheet(item: item)
                .presentationDetents([.medium])
        }
        }
        .background(Theme.screen)
        // 全屏详情 + zoom 转场：用 fullScreenCover 而非 push——
        // push + zoom 在 List 上交互式滑返有框架级残影 bug（Apple 论坛 thread 810944），
        // cover 同样有非线性放大、左缘滑动返回、缩回源行，且天然盖住/恢复 tab 栏
        .fullScreenCover(item: $detailItem) { item in
            NavigationStack {
                BookmarkDetailView(item: item)
            }
            .navigationTransition(.zoom(sourceID: item.id, in: zoomNS))
        }
        .overlay(alignment: .bottomTrailing) {
            FloatingAddButton { showAddSheet = true }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.sub)
                .font(.subheadline)
            TextField("搜索标题、链接、内容、标签", text: $query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.sub)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.card, in: Capsule())
        .padding(.horizontal, Theme.Space.page)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    private var tagFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip("全部", .all)
                ForEach(visibleTags, id: \.self) { tag in
                    filterChip(tag, .tag(tag))
                }
                if bookmarks.contains(where: { $0.tags.isEmpty }) {
                    filterChip("未打标", .untagged)
                }
            }
            .padding(.horizontal, Theme.Space.page)
            .padding(.vertical, 8)
        }
    }

    private func filterChip(_ label: String, _ value: TagFilter) -> some View {
        // filterStyle：筛选栏的刻意差异（内边距更大、选中加粗），见 SelectableChip 注释
        SelectableChip(label: label, selected: filter == value, filterStyle: true) {
            filter = value
        }
    }
}

/// 收藏卡片：链接收藏点击直接跳转，图文收藏点击进全屏详情；下方一排 tag 药丸
struct BookmarkCard: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.modelContext) private var context
    let item: InboxItem
    var onOpenDetail: () -> Void
    var onEditTags: () -> Void
    var onDelete: () -> Void

    private var url: URL? { item.urlString.flatMap(URL.init(string:)) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let data = item.sourceImage, let ui = UIImage(data: data) {
                // 图片收藏（分享截图等）：直接展示缩略图，比通用图标更好认
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 38, height: 38)
                    .clipShape(.rect(cornerRadius: 10))
            } else {
                BookmarkKindIcon(isLink: url != nil, size: 38)
            }
            VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.body)
                .foregroundStyle(Theme.text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if let url {
                Text(url.host() ?? url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(Theme.sub)
                    .lineLimit(1)
            } else if item.rawText != title {
                Text(item.rawText)
                    .font(.caption)
                    .foregroundStyle(Theme.sub)
                    .lineLimit(3)
            }
            HStack(spacing: 8) {
                if item.tags.isEmpty {
                    Text("未打标")
                        .font(.caption)
                        .foregroundStyle(Theme.sub.opacity(0.7))
                } else {
                    ForEach(item.tags, id: \.self) { TagPill(text: $0) }
                }
                Spacer()
                Text(item.createdAt.formatted(.relative(presentation: .named).locale(Locale(identifier: "zh_CN"))))
                    .font(.caption)
                    .foregroundStyle(Theme.sub)
            }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let url {
                // 链接型：点击直接跳转；打不开（畸形 URL）兜底进详情
                openURL(url) { accepted in
                    if !accepted { onOpenDetail() }
                }
            } else {
                onOpenDetail()
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive, action: onDelete) { Label("删除", systemImage: "trash") }
            Button(action: onEditTags) { Label("标签", systemImage: "tag") }
                .tint(Theme.green)
        }
        .contextMenu {
            if let url {
                Button { openURL(url) } label: { Label("打开链接", systemImage: "safari") }
                Button {
                    Task { await Ingestor.enrichBookmark(item, context: context, refetchTitle: true) }
                } label: {
                    Label("重新抓取标题", systemImage: "arrow.clockwise")
                }
            }
            // 链接型 tap 被跳转占用，详情/编辑入口从长按菜单补齐
            Button(action: onOpenDetail) { Label("查看详情", systemImage: "doc.text.magnifyingglass") }
            Button(action: onEditTags) { Label("编辑标签", systemImage: "tag") }
            Button(role: .destructive, action: onDelete) { Label("删除", systemImage: "trash") }
        }
    }

    private var title: String {
        if let bookmarkTitle = item.bookmarkTitle, !bookmarkTitle.isEmpty { return bookmarkTitle }
        // 没抓到标题的链接退回显示域名
        if let url { return url.host() ?? "链接" }
        // 纯文本收藏用首行当标题
        return item.rawText.components(separatedBy: .newlines).first ?? item.rawText
    }
}

/// 手动添加收藏：粘贴链接或输入一段文字
struct BookmarkAddSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var settings: AppSettings
    @State private var text = ""
    @State private var pickedItem: PhotosPickerItem?
    @State private var imageData: Data?
    @State private var selectedTags: [String] = []
    @State private var saving = false

    private var candidateTags: [String] { settings.bookmarkTags }
    private var canSave: Bool {
        !(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && imageData == nil) && !saving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("内容") {
                    TextField("粘贴链接，或输入要收藏的文字…", text: $text, axis: .vertical)
                        .lineLimit(4...10)
                        .textInputAutocapitalization(.never)
                }

                Section("图片") {
                    if let imageData, let ui = UIImage(data: imageData) {
                        HStack(spacing: 12) {
                            Image(uiImage: ui)
                                .resizable().scaledToFill()
                                .frame(width: 64, height: 64)
                                .clipShape(.rect(cornerRadius: 10))
                            Text("已添加图片").font(.subheadline).foregroundStyle(Theme.sub)
                            Spacer()
                            Button(role: .destructive) {
                                self.imageData = nil; pickedItem = nil
                            } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                    }
                    PhotosPicker(selection: $pickedItem, matching: .images) {
                        Label(imageData == nil ? "添加图片" : "更换图片", systemImage: "photo.on.rectangle")
                    }
                }

                if !candidateTags.isEmpty {
                    Section {
                        TagPicker(candidates: candidateTags, selection: $selectedTags)
                            .padding(.vertical, 2)
                    } header: {
                        Text("标签")
                    } footer: {
                        Text("不选则按内容自动打标（需配置 LLM）；标签在 设置 → 收藏标签 里管理。")
                    }
                }
            }
            .navigationTitle("添加收藏")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(!canSave)
                }
            }
            .onChange(of: pickedItem) { _, newItem in
                Task { imageData = try? await newItem?.loadTransferable(type: Data.self) }
            }
        }
    }

    private func save() {
        saving = true
        let content = text, image = imageData, tags = selectedTags
        Task {
            await Ingestor.ingestBookmark(text: content, sourceImage: image,
                                          manualTags: tags.isEmpty ? nil : tags,
                                          source: .manual, context: context)
            dismiss()
        }
    }
}

// FlowLayout 已随 chip 组件收进 Views/Components/TagPicker.swift

/// 编辑单条收藏的标签：从设置页的 tag 列表里勾选，支持 AI 重新打标
struct BookmarkTagSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var settings: AppSettings
    let item: InboxItem
    @State private var retagging = false
    @State private var retagMessage: String?
    @State private var retagFailed = false

    /// 可勾选的 tag：设置页列表 + 该条目已有但列表里没有的（不吞掉存量）
    private var candidates: [String] {
        settings.mergedTagCandidates(including: item.tags)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(candidates, id: \.self) { tag in
                        Button {
                            toggle(tag)
                        } label: {
                            HStack {
                                Text(tag).foregroundStyle(Theme.text)
                                Spacer()
                                if item.tags.contains(tag) {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                }
                            }
                        }
                    }
                } header: {
                    Text("标签")
                } footer: {
                    Text("标签列表在 设置 → 收藏标签 里管理。")
                }
                if settings.llmConfig != nil {
                    Section {
                        Button {
                            retag()
                        } label: {
                            HStack {
                                Label("AI 重新打标", systemImage: "sparkles")
                                if retagging { Spacer(); ProgressView().controlSize(.small) }
                            }
                        }
                        .disabled(retagging)
                    } footer: {
                        if let message = retagMessage {
                            Text(message)
                                .foregroundStyle(retagFailed ? Theme.red : Theme.green)
                        }
                    }
                }
            }
            .navigationTitle("编辑标签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func toggle(_ tag: String) {
        if let index = item.tags.firstIndex(of: tag) {
            item.tags.remove(at: index)
        } else {
            item.tags.append(tag)
        }
        try? context.save()
    }

    private func retag() {
        retagging = true
        retagMessage = nil
        Task {
            let error = await Ingestor.autoTag(item, context: context)
            if let error {
                retagFailed = true
                retagMessage = "打标失败：\(error)"
            } else if item.tags.isEmpty {
                retagFailed = false
                retagMessage = "AI 认为候选标签里没有贴切的，可手动勾选"
            } else {
                retagFailed = false
                retagMessage = "已打标：\(item.tags.joined(separator: "、"))"
            }
            retagging = false
        }
    }
}

// MARK: - 需修正页（截图待办确认 + 未分类）

struct ReviewView: View {
    @Query(filter: InboxItem.needsReviewPredicate,
           sort: \InboxItem.createdAt, order: .reverse)
    private var reviewItems: [InboxItem]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(reviewItems) { item in
                    ReviewCard(item: item)
                        .padding(.horizontal, Theme.Space.page)
                }
            }
            .padding(.vertical, 8)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.screen)
        .overlay {
            if reviewItems.isEmpty {
                ContentUnavailableView("没有需要处理的内容", systemImage: "checkmark.seal")
            }
        }
        .navigationTitle("需处理")
    }
}

/// 需处理单条卡片：点击正文可展开/收起全文（默认截断，长文本给提示）。
private struct ReviewCard: View {
    @Bindable var item: InboxItem
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var dida: DidaService
    @State private var expanded = false
    @State private var retrying = false
    @State private var retryError: String?

    private var fullText: String {
        item.kind == .todo ? (item.todoTitle ?? item.rawText) : item.rawText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Badge(text: item.kind == .todo ? "截图待办" : "未分类",
                      color: item.kind == .todo ? Theme.green : Theme.sub)
                Spacer()
                Text(item.createdAt.formatted(.relative(presentation: .named)))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.sub)
            }
            Text(fullText)
                .font(.system(size: 14.5, weight: item.kind == .todo ? .bold : .regular))
                .lineLimit(expanded ? nil : 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation { expanded.toggle() } }
            // 文本较长时给个展开/收起提示（粗略按长度判断，够用）
            if fullText.count > 60 {
                Text(expanded ? "收起" : "展开全文")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .onTapGesture { withAnimation { expanded.toggle() } }
            }
            if let imageData = item.sourceImage, let image = UIImage(data: imageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 90)
                    .clipShape(.rect(cornerRadius: 12))
                    .opacity(0.9)
            }
            if let error = retryError {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.red)
            }
            HStack(spacing: 8) {
                if item.kind == .todo {
                    Button("确认入库") {
                        item.needsReview = false
                        item.needsPush = true
                        try? context.save()
                        Task { await dida.syncNow(context: context) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                } else {
                    // 未分类/低置信条目：用原文重新走解析（偶发 LLM 抖动导致没识别出的，重试常能成）
                    Button {
                        retry()
                    } label: {
                        if retrying { ProgressView().controlSize(.small) }
                        else { Text("重新识别") }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(retrying)
                }
                Button("删除", role: .destructive) {
                    context.delete(item)
                    try? context.save()
                }
                .buttonStyle(.bordered)
                .disabled(retrying)
            }
            .controlSize(.small)
        }
        .cardStyle()
    }

    /// 重新识别：用原文按来源重跑解析管线，成功则删掉这条未分类项、新结果入对应分类。
    private func retry() {
        retrying = true
        retryError = nil
        let raw = item.rawText
        let source = item.source
        Task {
            // 截图来源走截图专用解析器，其余走默认管线
            let parser: (any Parser)? = source == .screenshot ? AppSettings.shared.screenParser : nil
            let newItems = await Ingestor.ingest(text: raw, source: source,
                                                 parser: parser, context: context)
            retrying = false
            // 新结果里有明确分类（非未分类）才算识别成功；否则删掉 ingest 可能新建的未分类项，避免重复
            let recognized = newItems.filter { $0.kind != .unclassified }
            if recognized.isEmpty {
                // 清理本次 ingest 可能产生的新未分类项（保留原条目让用户手动处理）
                for n in newItems where n.id != item.id { context.delete(n) }
                try? context.save()
                retryError = "仍无法识别，可保留手动处理或删除"
            } else {
                // 识别成功 → 删掉旧的未分类项（新结果已各自入库/进对应 Tab）
                context.delete(item)
                try? context.save()
            }
        }
    }
}

// MARK: - 回收站：软删除 / 恢复 / 彻底删除 / 到期清理

enum Trash {
    /// 软删除：进回收站（打时间戳），各列表默认不再展示。
    static func softDelete(_ item: InboxItem, context: ModelContext) {
        item.deletedAt = .now
        try? context.save()
    }
    static func restore(_ item: InboxItem, context: ModelContext) {
        item.deletedAt = nil
        try? context.save()
    }
    static func deleteForever(_ item: InboxItem, context: ModelContext) {
        context.delete(item)
        try? context.save()
    }
    /// 清理满 7 天的回收站条目（启动 / 回前台时调用）
    static func purgeExpired(context: ModelContext) {
        let cutoff = Date.now.addingTimeInterval(-Double(InboxItem.trashRetentionDays) * 86400)
        let descriptor = FetchDescriptor<InboxItem>(predicate: #Predicate { $0.deletedAt != nil })
        guard let candidates = try? context.fetch(descriptor) else { return }
        let expired = candidates.filter { ($0.deletedAt ?? .now) < cutoff }
        guard !expired.isEmpty else { return }
        for item in expired { context.delete(item) }
        try? context.save()
    }
}

/// 回收站页：展示已删除条目，可恢复 / 彻底删除；7 天自动清理。
struct TrashView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \InboxItem.deletedAt, order: .reverse) private var all: [InboxItem]

    private var trashed: [InboxItem] { all.trashed() }

    var body: some View {
        List {
            ForEach(trashed) { item in
                HStack(spacing: 12) {
                    Image(systemName: icon(item))
                        .foregroundStyle(Theme.sub)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(titleFor(item)).font(.body).lineLimit(1)
                        Text("\(kindName(item)) · \(item.trashDaysLeft) 天后彻底删除")
                            .font(.caption).foregroundStyle(Theme.sub)
                    }
                    Spacer()
                    Button { Trash.restore(item, context: context) } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .tint(Theme.accent)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        Trash.deleteForever(item, context: context)
                    } label: { Label("彻底删除", systemImage: "trash") }
                    Button { Trash.restore(item, context: context) } label: {
                        Label("恢复", systemImage: "arrow.uturn.backward")
                    }.tint(Theme.accent)
                }
            }
        }
        .overlay {
            if trashed.isEmpty {
                ContentUnavailableView("回收站为空", systemImage: "trash",
                                       description: Text("删除的快递、行程、收藏会在这里保留 7 天，之后自动清除"))
            }
        }
        .navigationTitle("回收站")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            if !trashed.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清空", role: .destructive) {
                        for item in trashed { context.delete(item) }
                        try? context.save()
                    }
                }
            }
        }
    }

    private func icon(_ i: InboxItem) -> String {
        switch i.kind {
        case .package: "shippingbox.fill"
        case .trip: "airplane"
        case .bookmark: "bookmark.fill"
        case .todo: "checkmark.circle"
        case .expense: "creditcard.fill"
        case .unclassified: "questionmark.circle"
        }
    }
    private func kindName(_ i: InboxItem) -> String {
        switch i.kind {
        case .package: "快递"; case .trip: "行程"; case .bookmark: "收藏"
        case .todo: "待办"; case .expense: "记账"; case .unclassified: "未分类"
        }
    }
    private func titleFor(_ i: InboxItem) -> String {
        switch i.kind {
        case .package: i.carrier ?? "快递"
        case .trip: i.tripKindRaw == "hotel" ? (i.departPlace ?? "住宿")
                    : i.tripNumber ?? "\(i.departPlace ?? "") → \(i.arrivePlace ?? "")"
        case .bookmark: i.bookmarkTitle ?? i.urlString ?? i.rawText
        case .todo: i.todoTitle ?? i.rawText
        case .expense: i.merchant ?? i.rawText
        case .unclassified: i.rawText
        }
    }
}

/// 新增待办：仿滴答的底部快捷输入条，贴着键盘上方。
/// 标题输入 + 一排小图标（日期 / 优先级），点图标弹出对应选择器；右侧圆形发送键保存。
/// 用 overlay 呈现而非 sheet，以便自己掌控「遮罩淡入 + 输入条弹簧滑入」的进出动效。
struct TodoQuickAdd: View {
    @Binding var isPresented: Bool
    @Environment(\.modelContext) private var context
    @State private var title = ""
    @State private var note = ""
    @State private var due: Date?
    @State private var priority = 0
    @State private var showDue = false
    @State private var showPriority = false
    /// 驱动进出动画：呈现后置 true 触发滑入，关闭前置 false 触发滑出
    @State private var shown = false
    @FocusState private var focus: Field?

    private enum Field { case title, note }

    /// drawer 手感：轻微回弹的弹簧（参考 Apple 抽屉规格 damping≈0.85 / response≈0.32）
    private let spring = Animation.spring(response: 0.34, dampingFraction: 0.86)

    private var canSave: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        ZStack(alignment: .bottom) {
            // 遮罩：淡入淡出，全屏（含键盘区），点击空白收起
            Color.black.opacity(shown ? 0.22 : 0)
                .ignoresSafeArea()
                .onTapGesture { close() }

            composer
                .offset(y: shown ? 0 : 320)
                .opacity(shown ? 1 : 0)
        }
        .onAppear {
            withAnimation(spring) { shown = true }
            focus = .title
        }
    }

    // MARK: 输入条

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题单行（不换行）；回车即创建当前待办并清空、保持焦点，实现连续创建
            TextField("准备做什么？", text: $title)
                .font(.system(size: 17))
                .focused($focus, equals: .title)
                .submitLabel(.done)
                .onSubmit { addAndContinue() }
                .padding(.top, 4)

            TextField("描述", text: $note, axis: .vertical)
                .lineLimit(2...4)
                .font(.footnote)
                .foregroundStyle(Theme.text)
                .focused($focus, equals: .note)

            HStack(spacing: 10) {
                // 截止时间：直接呈现日期页（不先收键盘，避免图标闪一下再收）
                Button { showDue = true } label: {
                    toolLabel(systemImage: "calendar",
                              tint: due == nil ? Theme.sub : Theme.accent,
                              active: due != nil,
                              trailingText: due.map(dueText))
                }
                .buttonStyle(PressableStyle(scale: 0.9))
                .sheet(isPresented: $showDue) {
                    DueDateSheet(due: $due)
                }
                .onChange(of: showDue) { _, now in
                    if !now { focus = .title }   // 关掉日期页后回焦标题并弹键盘
                }

                // 优先级：底部 sheet（彩色旗帜、无箭头）
                Button { showPriority = true } label: {
                    toolLabel(systemImage: priority == 0 ? "flag" : "flag.fill",
                              tint: priority == 0 ? Theme.sub : TodoPriority(raw: priority).color,
                              active: priority != 0,
                              trailingText: priority == 0 ? nil : TodoPriority(raw: priority).label.replacingOccurrences(of: "优先级", with: ""))
                }
                .buttonStyle(PressableStyle(scale: 0.9))
                .sheet(isPresented: $showPriority) { PrioritySheet(priority: $priority) }
                .onChange(of: showPriority) { _, now in
                    if !now { focus = .title }
                }

                Spacer(minLength: 0)

                Button { save() } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background((canSave ? Theme.accent : Theme.sub.opacity(0.35)).gradient, in: Circle())
                }
                .buttonStyle(PressableStyle(scale: 0.88))
                .disabled(!canSave)
                .animation(.snappy(duration: 0.18), value: canSave)
                .sensoryFeedback(.success, trigger: justSaved)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .background {
            // 材质只在顶部收圆角，底部向下铺到屏幕边缘（含键盘区），
            // 填住输入条平底与第三方输入法圆角顶之间左右两侧的缝隙。
            UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20, style: .continuous)
                .fill(.regularMaterial)
                .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .top) {   // 顶部一道细高光，托出材质边缘
            Rectangle().fill(.white.opacity(0.10)).frame(height: 0.5)
        }
        .shadow(color: .black.opacity(0.16), radius: 18, y: -3)
    }

    /// 工具标签：小圆底 + 图标，选中态展示彩色文字标签（今天 18:00 / 高）。
    /// 只做外观，供 Button（日期）与 Menu（优先级）复用。
    private func toolLabel(systemImage: String, tint: Color, active: Bool,
                          trailingText: String?) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage).font(.system(size: 16, weight: .medium))
            if let trailingText {
                Text(trailingText).font(.footnote.weight(.semibold))
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, active ? 11 : 0)
        .frame(minWidth: 34, minHeight: 34)
        .background(active ? tint.opacity(0.12) : Theme.fill, in: Capsule())
        .animation(.snappy(duration: 0.18), value: active)
    }

    @State private var justSaved = false

    private func dueText(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "今天 " + d.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInTomorrow(d) { return "明天 " + d.formatted(date: .omitted, time: .shortened) }
        return d.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day())
    }

    private func close() {
        focus = nil
        withAnimation(spring) { shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { isPresented = false }
    }

    /// 落库一条待办；返回是否成功（标题非空）。
    @discardableResult
    private func persist() -> Bool {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = InboxItem(kind: .todo, source: .manual, rawText: t)
        item.todoTitle = t
        item.todoNote = n.isEmpty ? nil : n
        item.todoDue = due
        item.todoPriority = priority
        context.insert(item)
        try? context.save()
        justSaved.toggle()
        return true
    }

    private func save() {
        guard persist() else { return }
        close()
    }

    /// 连续创建：回车即建，清空内容后停留弹窗、焦点回标题。
    /// 保留截止时间/优先级，方便批量录入同批待办。
    private func addAndContinue() {
        guard persist() else { return }
        title = ""
        note = ""
        focus = .title
    }
}

/// 时间行卡片的位置锚点：供 DueDateSheet 把时分浮层定位到「请选择」按钮上方。
private struct TimeRowAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// 截止时间：从底部弹出的独立页面（仿滴答）。X 取消 / ✓ 确认，
/// 顶部矢量快捷瓦片 + 自绘月历（农历/节气/节日）+ 时间行。用工作副本，取消不改动原值。
struct DueDateSheet: View {
    @Binding var due: Date?
    @Environment(\.dismiss) private var dismiss
    @State private var working: Date?
    @State private var hasTime: Bool
    /// 时分浮层是否可见：点「请选择」后在其上方浮出小时间选择器，点外部收起
    @State private var showTimePicker = false

    init(due: Binding<Date?>) {
        _due = due
        let base = due.wrappedValue
        _working = State(initialValue: base ?? Calendar.current.startOfDay(for: Date()))
        if let base {
            let c = Calendar.current.dateComponents([.hour, .minute], from: base)
            _hasTime = State(initialValue: (c.hour ?? 0) != 0 || (c.minute ?? 0) != 0)
        } else {
            _hasTime = State(initialValue: false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 18) {
                    quickTiles
                    MonthCalendarView(selection: $working)
                    timeRow
                    if working != nil { clearButton }
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .padding(.bottom, 20)
            }
        }
        // 时分浮层：通过时间行的锚点定位到「请选择」按钮上方（无箭头的小浮窗），
        // 挂在 body 层而非行内，避免被 ScrollView 裁剪、且能全屏接住"点外部收起"
        .overlayPreferenceValue(TimeRowAnchorKey.self) { anchor in
            if showTimePicker, let anchor {
                GeometryReader { proxy in
                    let rect = proxy[anchor]
                    let popW: CGFloat = 220, popH: CGFloat = 190
                    ZStack {
                        // 点浮层外任意处收起（近乎透明但可命中，同时挡住底下滚动）
                        Color.black.opacity(0.001)
                            .onTapGesture { withAnimation(.snappy) { showTimePicker = false } }
                        timePopover
                            .frame(width: popW, height: popH)
                            // 右缘对齐时间行卡片右缘（即「请选择」一侧），底缘悬在卡片上方 8pt
                            .position(x: min(rect.maxX - popW / 2, proxy.size.width - popW / 2 - 12),
                                      y: max(rect.minY - popH / 2 - 8, popH / 2 + 8))
                            .transition(.scale(scale: 0.9, anchor: .bottomTrailing).combined(with: .opacity))
                    }
                }
            }
        }
        .presentationDetents([.height(600)])
        .presentationDragIndicator(.hidden)
    }

    // MARK: 头部：圆形 ✕ / ✓

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 38, height: 38)
                    .background(Theme.fill, in: Circle())
            }
            .buttonStyle(PressableStyle(scale: 0.9))

            Spacer()
            Text("截止时间").font(.headline)
            Spacer()

            Button { confirm() } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Theme.accent, in: Circle())
            }
            .buttonStyle(PressableStyle(scale: 0.9))
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: 快捷瓦片（矢量图标）

    private var quickTiles: some View {
        HStack(spacing: 10) {
            tile("今天", Color(.systemBlue), date: startOfToday, time: false) {
                CalendarGlyph(text: "\(todayNum)", color: $0)
            }
            tile("明天", Color(.systemOrange), date: dayAfter(1), time: false) {
                SunriseGlyph(color: $0)
            }
            tile("下周一", Color(.systemBlue), date: nextMonday, time: false) {
                CalendarGlyph(text: "Mo", color: $0)
            }
            tile("今天傍晚", Color(.systemIndigo), date: todayEvening, time: true) {
                SunsetGlyph(color: $0)
            }
        }
    }

    private func tile<G: View>(_ title: String, _ tint: Color, date: Date, time: Bool,
                               @ViewBuilder glyph: @escaping (Color) -> G) -> some View {
        let selected = working.map { Calendar.current.isDate($0, equalTo: date, toGranularity: .minute) } ?? false
        return Button {
            withAnimation(.snappy) { working = date; hasTime = time }
        } label: {
            VStack(spacing: 7) {
                glyph(tint).frame(width: 28, height: 28)
                Text(title)
                    .font(.caption)
                    .fontWeight(selected ? .semibold : .regular)
                    .foregroundStyle(selected ? tint : Theme.sub)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    // MARK: 时间行

    private var timeRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock").foregroundStyle(Theme.accent)
            Text("时间").foregroundStyle(Theme.text)
            Spacer()
            if hasTime {
                // 已设时间：右侧显示当前时分（点击可重开浮层微调），点 ✕ 清除
                Button { withAnimation(.snappy) { showTimePicker.toggle() } } label: {
                    Text(timeBinding.wrappedValue.formatted(date: .omitted, time: .shortened))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                Button { withAnimation(.snappy) { hasTime = false; showTimePicker = false } } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.sub)
                }
                .buttonStyle(.plain)
            } else {
                // 未设时间：点「请选择」在按钮上方浮出小时间选择器（不再向下展开占位）
                Button { withAnimation(.snappy) { enableTime(); showTimePicker = true } } label: {
                    HStack(spacing: 3) {
                        Text("请选择")
                        Image(systemName: "chevron.up").font(.caption2.weight(.semibold))
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 18)
        .background(Theme.card,
                    in: .rect(cornerRadius: 12))
        // 记录时间行卡片位置，供浮层定位到「请选择」上方
        .anchorPreference(key: TimeRowAnchorKey.self, value: .bounds) { $0 }
    }

    /// 浮层时间选择器：无箭头的小浮窗（圆角卡片 + 阴影），滚轮直接选，点外部收起。
    private var timePopover: some View {
        DatePicker("", selection: timeBinding, displayedComponents: .hourAndMinute)
            .datePickerStyle(.wheel)
            .labelsHidden()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .background(Theme.card, in: .rect(cornerRadius: 14))
            .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
    }

    /// 开启具体时间：在当前所选日期上落到 9:00（可再点 compact 控件调整）。
    private func enableTime() {
        let cal = Calendar.current
        let base = working ?? cal.startOfDay(for: Date())
        working = cal.date(bySettingHour: 9, minute: 0, second: 0, of: base) ?? base
        hasTime = true
    }

    /// compact 时间控件的绑定（仅在已设时间时使用）。
    private var timeBinding: Binding<Date> {
        Binding(
            get: { working ?? (Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()) },
            set: { working = $0; hasTime = true }
        )
    }

    private var clearButton: some View {
        Button {
            // 清除即生效：直接置空并退出，无需再点完成/取消
            due = nil
            dismiss()
        } label: {
            Label("清除截止时间", systemImage: "xmark.circle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.red)
        }
        .buttonStyle(PressableStyle())
    }

    // MARK: 确认 / 日期工具

    private func confirm() {
        if let w = working {
            due = hasTime ? w : Calendar.current.startOfDay(for: w)
        } else {
            due = nil
        }
        dismiss()
    }

    private var todayNum: Int { Calendar.current.component(.day, from: Date()) }
    private var startOfToday: Date { Calendar.current.startOfDay(for: Date()) }
    private func dayAfter(_ n: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: n, to: startOfToday) ?? startOfToday
    }
    private var todayEvening: Date {
        Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: Date()) ?? Date()
    }
    private var nextMonday: Date {
        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: startOfToday)
        let delta = (9 - weekday) % 7
        return cal.date(byAdding: .day, value: delta == 0 ? 7 : delta, to: startOfToday) ?? startOfToday
    }
}

/// 自绘月历：周一起排，公历数字 + 农历/节气/节日副标题，支持上下月切换、今天/选中态。
struct MonthCalendarView: View {
    @Binding var selection: Date?
    @State private var month: Date
    /// 切月方向：true=向后（下个月，新页从右侧滑入），false=向前
    @State private var slideForward = true

    private let cal: Calendar
    private let lunar = ChineseCalendar()
    private let weekdays = ["一", "二", "三", "四", "五", "六", "日"]

    init(selection: Binding<Date?>) {
        _selection = selection
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "zh_CN")
        c.firstWeekday = 2   // 周一起排
        cal = c
        _month = State(initialValue: selection.wrappedValue ?? Date())
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            HStack(spacing: 0) {
                ForEach(weekdays, id: \.self) { d in
                    Text(d).font(.footnote).foregroundStyle(Theme.sub).frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 4) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    if let day { cell(day) } else { Color.clear.frame(height: 48) }
                }
            }
            .id(month)
            // 切月：新页从切换方向滑入、旧页反向滑出（左右切换动画，四.4）
            .transition(.asymmetric(
                insertion: .move(edge: slideForward ? .trailing : .leading).combined(with: .opacity),
                removal: .move(edge: slideForward ? .leading : .trailing).combined(with: .opacity)))
        }
        .clipped()
        .contentShape(Rectangle())
        // 左右滑动切换月份（垂直滚动仍归外层 ScrollView）
        .gesture(
            DragGesture(minimumDistance: 24)
                .onEnded { g in
                    guard abs(g.translation.width) > abs(g.translation.height) else { return }
                    shift(g.translation.width < 0 ? 1 : -1)
                }
        )
    }

    private var header: some View {
        HStack {
            Button { shift(-1) } label: {
                Image(systemName: "chevron.left").font(.body.weight(.semibold))
            }
            Spacer()
            Text(monthTitle).font(.headline)
            Spacer()
            Button { shift(1) } label: {
                Image(systemName: "chevron.right").font(.body.weight(.semibold))
            }
        }
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 6)
    }

    /// 当月按周一起排的格子；前导空位为 nil。
    private var days: [Date?] {
        guard let first = cal.date(from: cal.dateComponents([.year, .month], from: month)),
              let range = cal.range(of: .day, in: .month, for: first) else { return [] }
        let weekday = cal.component(.weekday, from: first)      // 1=周日…7=周六
        let lead = (weekday - cal.firstWeekday + 7) % 7
        var arr: [Date?] = Array(repeating: nil, count: lead)
        for d in range { arr.append(cal.date(byAdding: .day, value: d - 1, to: first)) }
        while arr.count % 7 != 0 { arr.append(nil) }
        return arr
    }

    private var monthTitle: String { OmnyDateFormat.monthTitle(month) }

    private func shift(_ delta: Int) {
        if let m = cal.date(byAdding: .month, value: delta, to: month) {
            slideForward = delta > 0
            withAnimation(.snappy(duration: 0.28)) { month = m }
        }
    }

    private func cell(_ day: Date) -> some View {
        let ann = lunar.annotation(for: day)
        let selected = selection.map { cal.isDate(day, inSameDayAs: $0) } ?? false
        let isToday = cal.isDateInToday(day)
        let dayNum = cal.component(.day, from: day)
        return Button { select(day) } label: {
            VStack(spacing: 1) {
                Text("\(dayNum)")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(selected ? .white : (isToday ? Theme.accent : Theme.text))
                Text(ann.text)
                    .font(.system(size: 9.5))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(selected ? .white.opacity(0.9) : subtitleColor(ann.kind))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accent)
                } else if isToday {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accent.opacity(0.12))
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func subtitleColor(_ kind: DayAnnotation.Kind) -> Color {
        switch kind {
        case .festival:   Theme.green
        case .solarTerm:  Theme.green
        case .lunarMonth: Color(.systemOrange)
        case .lunarDay:   Theme.sub
        }
    }

    /// 选中某天：保留原有时间部分（若无则用 00:00），只改年月日。
    private func select(_ day: Date) {
        let base = selection ?? day
        let t = cal.dateComponents([.hour, .minute], from: base)
        var comps = cal.dateComponents([.year, .month, .day], from: day)
        comps.hour = t.hour; comps.minute = t.minute
        selection = cal.date(from: comps)
    }
}

// MARK: - 快捷瓦片的矢量图标（Path/Canvas 自绘，替代 SF Symbol）

/// 日历图标：顶部两个挂钩 + 外框 + 居中文字（今天日号 / “Mo”）。
struct CalendarGlyph: View {
    var text: String
    var color: Color
    var body: some View {
        VStack(spacing: 1.5) {
            HStack(spacing: 7) {
                Capsule().frame(width: 2, height: 4)
                Capsule().frame(width: 2, height: 4)
            }
            .foregroundStyle(color)
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(color, lineWidth: 1.8)
                Text(text)
                    .font(.system(size: text.count > 1 ? 10 : 12, weight: .bold))
                    .foregroundStyle(color)
            }
            .frame(width: 23, height: 21)
        }
    }
}

/// 日出图标：地平线 + 半日 + 上箭头 + 两侧短射线。
struct SunriseGlyph: View {
    var color: Color
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let baseY = h * 0.72
            let r = w * 0.22
            let s = StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)

            var horizon = Path()
            horizon.move(to: CGPoint(x: w * 0.08, y: baseY))
            horizon.addLine(to: CGPoint(x: w * 0.92, y: baseY))
            ctx.stroke(horizon, with: .color(color), style: s)

            var sun = Path()
            sun.addArc(center: CGPoint(x: w / 2, y: baseY), radius: r,
                       startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
            ctx.stroke(sun, with: .color(color), style: s)

            var arrow = Path()
            let ax = w / 2
            arrow.move(to: CGPoint(x: ax - 3.4, y: baseY - r - 2.5))
            arrow.addLine(to: CGPoint(x: ax, y: baseY - r - 6.5))
            arrow.addLine(to: CGPoint(x: ax + 3.4, y: baseY - r - 2.5))
            ctx.stroke(arrow, with: .color(color), style: s)

            for dx in [-1.0, 1.0] {
                var ray = Path()
                let x = w / 2 + CGFloat(dx) * (r + 5)
                ray.move(to: CGPoint(x: x, y: baseY - 2))
                ray.addLine(to: CGPoint(x: x, y: baseY - 6))
                ctx.stroke(ray, with: .color(color), style: s)
            }
        }
    }
}

/// 日落图标：地平线 + 半日 + 下箭头（太阳下沉）+ 两侧短射线。照 SunriseGlyph 的手绘 Path 路子，箭头改朝下。
struct SunsetGlyph: View {
    var color: Color
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let baseY = h * 0.72
            let r = w * 0.22
            let s = StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)

            // 地平线
            var horizon = Path()
            horizon.move(to: CGPoint(x: w * 0.08, y: baseY))
            horizon.addLine(to: CGPoint(x: w * 0.92, y: baseY))
            ctx.stroke(horizon, with: .color(color), style: s)

            // 半日（地平线之上）
            var sun = Path()
            sun.addArc(center: CGPoint(x: w / 2, y: baseY), radius: r,
                       startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
            ctx.stroke(sun, with: .color(color), style: s)

            // 下箭头（太阳下沉）：竖线在半日之上，箭头朝下指向地平线
            let ax = w / 2
            var stem = Path()
            stem.move(to: CGPoint(x: ax, y: baseY - r - 7))
            stem.addLine(to: CGPoint(x: ax, y: baseY - r - 1.5))
            ctx.stroke(stem, with: .color(color), style: s)
            var head = Path()
            head.move(to: CGPoint(x: ax - 3.4, y: baseY - r - 4.5))
            head.addLine(to: CGPoint(x: ax, y: baseY - r - 1))
            head.addLine(to: CGPoint(x: ax + 3.4, y: baseY - r - 4.5))
            ctx.stroke(head, with: .color(color), style: s)

            // 两侧短射线
            for dx in [-1.0, 1.0] {
                var ray = Path()
                let x = w / 2 + CGFloat(dx) * (r + 5)
                ray.move(to: CGPoint(x: x, y: baseY - 2))
                ray.addLine(to: CGPoint(x: x, y: baseY - 6))
                ctx.stroke(ray, with: .color(color), style: s)
            }
        }
    }
}

/// 优先级选择：底部 sheet（无箭头、Apple 动作表风格），彩色旗帜按 高→中→低→无 排列，选中打勾。
struct PrioritySheet: View {
    @Binding var priority: Int
    @Environment(\.dismiss) private var dismiss
    private let order: [TodoPriority] = [.high, .medium, .low, .none]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(order) { p in
                Button {
                    priority = p.rawValue
                    dismiss()
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "flag.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(p.color)
                            .frame(width: 24)
                        Text(p.label).font(.body).foregroundStyle(Theme.text)
                        Spacer()
                        if p.rawValue == priority {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .padding(.horizontal, 20)
                    // 每个选项加高，与弹窗高度更匹配（四.6）
                    .padding(.vertical, 20)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if p != order.last { Divider().padding(.leading, 58) }
            }
        }
        .padding(.top, 12)
        .presentationDetents([.height(340)])
        .presentationDragIndicator(.visible)
    }
}
