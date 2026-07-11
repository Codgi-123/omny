import SwiftUI
import SwiftData
import PhotosUI
import OmnyCore

// MARK: - 快递页：待取 / 在途 / 已签收

struct ExpressView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \InboxItem.createdAt, order: .reverse) private var items: [InboxItem]

    private var packages: [InboxItem] { items.filter { $0.kind == .package && $0.deletedAt == nil } }

    @State private var pendingDelete: InboxItem?   // 待确认删除的快递（非 nil 时弹确认框）

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader("快递") { NavActions() }
            List {
                group("待取", packages.filter { $0.packageStatus == .awaitingPickup })
                group("在途", packages.filter { $0.packageStatus < .awaitingPickup })
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
        }
        .background(Theme.screen)
        .toolbar(.hidden, for: .navigationBar)
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
    private func group(_ title: String, _ list: [InboxItem], dimmed: Bool = false) -> some View {
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
                }
            } header: {
                sectionHeader(title)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline).fontWeight(.semibold)
            .foregroundStyle(Theme.sub)
            .textCase(nil)
    }
}

// MARK: - 行程页：即将出行 / 历史

struct TripView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \InboxItem.createdAt, order: .reverse) private var items: [InboxItem]

    private var trips: [InboxItem] { items.filter { $0.kind == .trip && $0.deletedAt == nil } }
    private var upcoming: [InboxItem] {
        trips.filter { ($0.departAt ?? .distantPast) > .now }
            .sorted { ($0.departAt ?? .distantFuture) < ($1.departAt ?? .distantFuture) }
    }
    private var past: [InboxItem] {
        trips.filter { ($0.departAt ?? .distantPast) <= .now }
            .sorted { ($0.departAt ?? .distantPast) > ($1.departAt ?? .distantPast) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader("行程") { NavActions() }
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
        .background(Theme.screen)
        .toolbar(.hidden, for: .navigationBar)
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

    private var todos: [InboxItem] {
        items.filter { $0.kind == .todo && !$0.deletedLocally && !$0.needsReview && $0.deletedAt == nil }
    }

    private var openTodos: [InboxItem] { todos.filter { !$0.todoCompleted } }

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

    var body: some View {
        VStack(spacing: 0) {
            todoHeader
            List {
            let open = openTodos
            // 按优先级分组：高 → 中 → 低 → 无；组内按截止时间倒序
            ForEach([TodoPriority.high, .medium, .low, .none]) { p in
                let group = sortedByDue(open.filter { $0.todoPriority == p.rawValue })
                if !group.isEmpty {
                    Section {
                        ForEach(group) { TodoRow(item: $0).cardCell(pad: 8) }
                    } header: {
                        HStack(spacing: 6) {
                            Image(systemName: "flag.fill")
                                .font(.caption2)
                                .foregroundStyle(p.color)
                            Text(p.label)
                            Text("\(group.count)").foregroundStyle(Theme.sub)
                        }
                        .font(.subheadline.weight(.medium))
                        .textCase(nil)
                        .sectionHeaderInset()
                    }
                }
            }

            let done = todos.filter(\.todoCompleted)
            if !done.isEmpty {
                Section {
                    if showCompleted {
                        ForEach(done) { TodoRow(item: $0).opacity(0.6).cardCell(pad: 8) }
                    }
                } header: {
                    Button {
                        withAnimation(.snappy) { showCompleted.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Text("已完成")
                            Text("\(done.count)").foregroundStyle(Theme.sub)
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.sub)
                                .rotationEffect(.degrees(showCompleted ? 0 : -90))
                        }
                        .font(.subheadline.weight(.medium))
                        .textCase(nil)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .sectionHeaderInset()
                }
            }
        }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // 包一层非结构化 Task：.refreshable 的任务绑定在刷新手势上，视图刷新时会被
            // SwiftUI 取消并把取消传给 URLSession（表现为"同步失败：cancelled"）。
            // Task {} 不继承外层取消，await .value 让菊花转到同步真正结束。
            .refreshable { await Task { await dida.syncNow(context: context) }.value }
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

    private var bookmarks: [InboxItem] { items.filter { $0.kind == .bookmark && $0.deletedAt == nil } }

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
        var tags = settings.bookmarkTags
        for item in bookmarks {
            for tag in item.tags where !tags.contains(tag) { tags.append(tag) }
        }
        return tags
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
                             onOpen: { detailItem = item },
                             onEditTags: { editingItem = item },
                             onDelete: {
                                 withAnimation(.snappy) { Trash.softDelete(item, context: context) }
                             })
                    .cardCell()
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
        .sheet(item: $detailItem) { item in
            BookmarkDetailSheet(item: item)
        }
        }
        .background(Theme.screen)
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
        let selected = filter == value
        return Button {
            filter = value
        } label: {
            Text(label)
                .font(.subheadline)
                .fontWeight(selected ? .semibold : .regular)
                .foregroundStyle(selected ? .white : Theme.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(selected ? Theme.accent : Theme.card, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// 收藏卡片：链接收藏可点开，纯文本收藏展示原文；下方一排 tag
struct BookmarkCard: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.modelContext) private var context
    let item: InboxItem
    var onOpen: () -> Void
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
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                IconChip(symbol: url != nil ? "link" : "text.alignleft", color: Theme.bookmark, size: 38)
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
                    ForEach(item.tags, id: \.self) { Badge(text: "#\($0)", color: Theme.green) }
                }
                Spacer()
                Text(item.createdAt.formatted(.relative(presentation: .named).locale(Locale(identifier: "zh_CN"))))
                    .font(.caption)
                    .foregroundStyle(Theme.sub)
            }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
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
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                        FlowLayout(spacing: 8) {
                            ForEach(candidateTags, id: \.self) { tag in
                                let on = selectedTags.contains(tag)
                                Button {
                                    if on { selectedTags.removeAll { $0 == tag } }
                                    else { selectedTags.append(tag) }
                                } label: {
                                    Text(tag)
                                        .font(.subheadline)
                                        .foregroundStyle(on ? .white : Theme.text)
                                        .padding(.horizontal, 12).padding(.vertical, 6)
                                        .background(on ? Theme.accent : Theme.card, in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
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

/// 简易流式布局：标签胶囊按宽度自动换行（iOS 16+ Layout 协议）。
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

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
        var tags = settings.bookmarkTags
        for tag in item.tags where !tags.contains(tag) { tags.append(tag) }
        return tags
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
    @Query(filter: #Predicate<InboxItem> { $0.needsReview && !$0.deletedLocally },
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
                    .clipShape(RoundedRectangle(cornerRadius: 12))
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

    private var trashed: [InboxItem] { all.filter { $0.deletedAt != nil } }

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
        case .unclassified: "questionmark.circle"
        }
    }
    private func kindName(_ i: InboxItem) -> String {
        switch i.kind {
        case .package: "快递"; case .trip: "行程"; case .bookmark: "收藏"
        case .todo: "待办"; case .unclassified: "未分类"
        }
    }
    private func titleFor(_ i: InboxItem) -> String {
        switch i.kind {
        case .package: i.carrier ?? "快递"
        case .trip: i.tripNumber ?? "\(i.departPlace ?? "") → \(i.arrivePlace ?? "")"
        case .bookmark: i.bookmarkTitle ?? i.urlString ?? i.rawText
        case .todo: i.todoTitle ?? i.rawText
        case .unclassified: i.rawText
        }
    }
}

/// 收藏详情：查看内容 / 图片 / 链接 / 标签，点「编辑」后可改内容、换图、改标签。
struct BookmarkDetailSheet: View {
    @Bindable var item: InboxItem
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openURL) private var openURL

    @State private var editing = false
    @State private var draftText = ""
    @State private var selectedTags: [String] = []
    @State private var pickedItem: PhotosPickerItem?

    private var url: URL? { item.urlString.flatMap(URL.init(string:)) }
    private var candidateTags: [String] {
        var tags = settings.bookmarkTags
        for t in item.tags where !tags.contains(t) { tags.append(t) }
        return tags
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("内容") {
                    if editing {
                        TextField("内容", text: $draftText, axis: .vertical).lineLimit(3...12)
                    } else if item.rawText.isEmpty {
                        Text("（无文字）").foregroundStyle(Theme.sub)
                    } else {
                        Text(item.rawText).textSelection(.enabled)
                    }
                }

                if let url {
                    Section("链接") {
                        Button { openURL(url) } label: {
                            Label(url.absoluteString, systemImage: "safari").lineLimit(1)
                        }
                    }
                }

                if let data = item.sourceImage, let ui = UIImage(data: data) {
                    Section("图片") {
                        Image(uiImage: ui).resizable().scaledToFit()
                            .frame(maxHeight: 280)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        if editing {
                            PhotosPicker(selection: $pickedItem, matching: .images) {
                                Label("更换图片", systemImage: "photo")
                            }
                            Button(role: .destructive) {
                                item.sourceImage = nil; try? context.save()
                            } label: { Label("移除图片", systemImage: "trash") }
                        }
                    }
                } else if editing {
                    Section("图片") {
                        PhotosPicker(selection: $pickedItem, matching: .images) {
                            Label("添加图片", systemImage: "photo.on.rectangle")
                        }
                    }
                }

                Section("标签") {
                    if editing {
                        FlowLayout(spacing: 8) {
                            ForEach(candidateTags, id: \.self) { tag in
                                let on = selectedTags.contains(tag)
                                Button {
                                    if on { selectedTags.removeAll { $0 == tag } }
                                    else { selectedTags.append(tag) }
                                } label: {
                                    Text(tag).font(.subheadline)
                                        .foregroundStyle(on ? .white : Theme.text)
                                        .padding(.horizontal, 12).padding(.vertical, 6)
                                        .background(on ? Theme.accent : Theme.card, in: Capsule())
                                }.buttonStyle(.plain)
                            }
                        }.padding(.vertical, 2)
                    } else if item.tags.isEmpty {
                        Text("未打标").foregroundStyle(Theme.sub)
                    } else {
                        FlowLayout(spacing: 8) {
                            ForEach(item.tags, id: \.self) { Badge(text: "#\($0)", color: Theme.green) }
                        }.padding(.vertical, 2)
                    }
                }
            }
            .navigationTitle("收藏详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(editing ? "取消" : "关闭") {
                        if editing { editing = false } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if editing {
                        Button("完成") { saveEdits() }
                    } else {
                        Button("编辑") { startEditing() }
                    }
                }
            }
            .onChange(of: pickedItem) { _, newItem in
                Task {
                    if let data = try? await newItem?.loadTransferable(type: Data.self) {
                        item.sourceImage = data; try? context.save()
                    }
                }
            }
        }
    }

    private func startEditing() {
        draftText = item.rawText
        selectedTags = item.tags
        editing = true
    }
    private func saveEdits() {
        item.rawText = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let info = RuleParser.extractBookmark(item.rawText) {
            item.urlString = info.url.absoluteString
            if (item.bookmarkTitle ?? "").isEmpty { item.bookmarkTitle = info.title }
        }
        item.tags = selectedTags
        try? context.save()
        editing = false
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
            TextField("准备做什么？", text: $title, axis: .vertical)
                .lineLimit(1...4)
                .font(.system(size: 17))
                .focused($focus, equals: .title)
                .submitLabel(.next)
                .onSubmit { focus = .note }
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
        .background(active ? tint.opacity(0.12) : Color(.tertiarySystemFill), in: Capsule())
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

    private func save() {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = InboxItem(kind: .todo, source: .manual, rawText: t)
        item.todoTitle = t
        item.todoNote = n.isEmpty ? nil : n
        item.todoDue = due
        item.todoPriority = priority
        context.insert(item)
        try? context.save()
        justSaved.toggle()
        close()
    }
}

/// 截止时间：从底部弹出的独立页面（仿滴答）。X 取消 / ✓ 确认，
/// 顶部矢量快捷瓦片 + 自绘月历（农历/节气/节日）+ 时间行。用工作副本，取消不改动原值。
struct DueDateSheet: View {
    @Binding var due: Date?
    @Environment(\.dismiss) private var dismiss
    @State private var working: Date?
    @State private var hasTime: Bool

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
                    .background(Color(.tertiarySystemFill), in: Circle())
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
                MoonGlyph(color: $0)
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
                // 已设时间：系统 compact 控件，点一下即弹原生小浮层（就在此处、无箭头）
                DatePicker("", selection: timeBinding, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                Button { withAnimation(.snappy) { hasTime = false } } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.sub)
                }
                .buttonStyle(.plain)
            } else {
                // 未设时间：默认展示「请选择」，点一下开启（落到 9:00，可再点调整）
                Button { withAnimation(.snappy) { enableTime() } } label: {
                    HStack(spacing: 3) {
                        Text("请选择")
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
            .transition(.opacity)
        }
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

    private var monthTitle: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月"
        return f.string(from: month)
    }

    private func shift(_ delta: Int) {
        if let m = cal.date(byAdding: .month, value: delta, to: month) {
            withAnimation(.snappy(duration: 0.2)) { month = m }
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

/// 月亮图标：外圆挖去偏移的内圆得到月牙（even-odd 填充）。
struct MoonGlyph: View {
    var color: Color
    var body: some View {
        Canvas { ctx, size in
            let r = size.width * 0.34
            let cx = size.width * 0.5, cy = size.height * 0.5
            var p = Path()
            p.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
            let off = r * 0.66
            p.addEllipse(in: CGRect(x: cx - r + off, y: cy - r - off * 0.45,
                                    width: 2 * r, height: 2 * r))
            ctx.fill(p, with: .color(color), style: FillStyle(eoFill: true))
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
                    .padding(.vertical, 15)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if p != order.last { Divider().padding(.leading, 58) }
            }
        }
        .padding(.top, 10)
        .presentationDetents([.height(288)])
        .presentationDragIndicator(.visible)
    }
}
