import SwiftUI
import SwiftData
import PhotosUI
import OmnyCore

// MARK: - 快递页：待取 / 在途 / 已签收

struct ExpressView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \InboxItem.createdAt, order: .reverse) private var items: [InboxItem]

    private var packages: [InboxItem] { items.filter { $0.kind == .package && $0.deletedAt == nil } }

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
    }

    @ViewBuilder
    private func group(_ title: String, _ list: [InboxItem], dimmed: Bool = false) -> some View {
        if !list.isEmpty {
            Section {
                ForEach(list) { pkg in
                    PackageCard(item: pkg).opacity(dimmed ? 0.55 : 1).cardCell()
                        // 左滑（trailing）完成/撤销（提醒事项式）
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if pkg.packageStatus == .pickedUp {
                                Button {
                                    withAnimation(.snappy) { pkg.packageStatus = .awaitingPickup }
                                    try? context.save()
                                } label: { Label("撤销", systemImage: "arrow.uturn.left") }
                            } else {
                                Button {
                                    withAnimation(.snappy) { pkg.packageStatus = .pickedUp }
                                    try? context.save()
                                } label: { Label("已取", systemImage: "checkmark") }
                                    .tint(Theme.green)
                            }
                        }
                        // 右滑（leading）删除 → 回收站
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                withAnimation(.snappy) { Trash.softDelete(pkg, context: context) }
                            } label: { Label("删除", systemImage: "trash") }
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

    private var todos: [InboxItem] {
        items.filter { $0.kind == .todo && !$0.deletedLocally && !$0.needsReview }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader("待办") { NavActions() }
            syncBar   // 纤细同步状态条，置顶不占版面
            List {
            let open = todos.filter { !$0.todoCompleted }
            if !open.isEmpty {
                Section { ForEach(open) { TodoRow(item: $0) } }
            }

            let done = todos.filter(\.todoCompleted)
            if !done.isEmpty {
                Section {
                    ForEach(done) { TodoRow(item: $0).opacity(0.6) }
                } header: {
                    Text("已完成").textCase(nil)
                }
            }
        }
            .listStyle(.insetGrouped)
            // 包一层非结构化 Task：.refreshable 的任务绑定在刷新手势上，视图刷新时会被
            // SwiftUI 取消并把取消传给 URLSession（表现为"同步失败：cancelled"）。
            // Task {} 不继承外层取消，await .value 让菊花转到同步真正结束。
            .refreshable { await Task { await dida.syncNow(context: context) }.value }
        }
        .background(Theme.screen)
        .overlay(alignment: .bottomTrailing) {
            FloatingAddButton { showAdd = true }
        }
        .sheet(isPresented: $showAdd) { TodoAddSheet() }
        .toolbar(.hidden, for: .navigationBar)
    }

    /// 顶部纤细同步条：一行显示滴答绑定/同步状态，可点刷新，不再占用大块版面。
    private var syncBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(settings.didaBound ? Theme.green : Theme.sub)
                .frame(width: 7, height: 7)
            Text(syncLine)
                .font(.caption)
                .foregroundStyle(Theme.sub)
                .lineLimit(1)
            Spacer()
            if dida.syncing {
                ProgressView().controlSize(.mini)
            } else if settings.didaBound {
                Button { Task { await dida.syncNow(context: context) } } label: {
                    Image(systemName: "arrow.clockwise").font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, Theme.Space.page)
        .padding(.vertical, 7)
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

/// 新增待办：标题 + 可选截止时间。与收藏统一走右下角「+」入口。
struct TodoAddSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var title = ""
    @State private var hasDue = false
    @State private var due = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section("内容") {
                    TextField("待办内容…", text: $title, axis: .vertical).lineLimit(1...4)
                }
                Section("截止时间") {
                    Toggle("设置截止时间", isOn: $hasDue.animation())
                    if hasDue { DatePicker("截止", selection: $due) }
                }
            }
            .navigationTitle("新增待办")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
    private func save() {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        let item = InboxItem(kind: .todo, source: .manual, rawText: t)
        item.todoTitle = t
        item.todoDue = hasDue ? due : nil
        context.insert(item)
        try? context.save()
        dismiss()
    }
}
