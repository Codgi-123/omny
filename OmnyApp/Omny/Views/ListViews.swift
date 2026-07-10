import SwiftUI
import SwiftData
import OmnyCore

// MARK: - 快递页：待取 / 在途 / 已签收

struct ExpressView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \InboxItem.createdAt, order: .reverse) private var items: [InboxItem]

    private var packages: [InboxItem] { items.filter { $0.kind == .package } }

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
                        // 整条右滑完成/撤销（提醒事项式）
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
    @Query(sort: \InboxItem.createdAt, order: .reverse) private var items: [InboxItem]

    private var trips: [InboxItem] { items.filter { $0.kind == .trip } }
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
                    ForEach(upcoming) { TripCard(item: $0).cardCell() }
                } header: {
                    tripHeader("即将出行")
                }
            }
            if !past.isEmpty {
                Section {
                    ForEach(past) { item in
                        HStack {
                            Text("\(item.tripNumber ?? "") \(item.departPlace ?? "") → \(item.arrivePlace ?? "")")
                                .font(.body)
                            Spacer()
                            Badge(text: "已结束")
                        }
                        .opacity(0.7)
                        .cardCell()
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
    @State private var newTodoTitle = ""

    private var todos: [InboxItem] {
        items.filter { $0.kind == .todo && !$0.deletedLocally && !$0.needsReview }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader("待办") { NavActions() }
            List {
            Section {
                syncBanner
                addField
            }

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
        .toolbar(.hidden, for: .navigationBar)
    }

    private var addField: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(Theme.accent)
                .font(.title2)
            TextField("添加待办…", text: $newTodoTitle)
                .textFieldStyle(.plain)
                .onSubmit(addTodo)
        }
    }

    private var syncBanner: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(settings.didaBound ? "滴答清单 · \(settings.didaProjectName ?? "")" : "滴答清单未绑定")
                    .font(.body)
                Text(bannerDetail)
                    .font(.caption)
                    .foregroundStyle(Theme.sub)
            }
            Spacer()
            if dida.syncing {
                ProgressView().controlSize(.small)
            } else if settings.didaBound {
                Badge(text: "已同步", color: Theme.green)
            } else {
                Badge(text: "本地模式", color: Theme.sub)
            }
        }
    }

    private var bannerDetail: String {
        if let error = dida.lastError { return error }
        if let last = settings.didaLastSync {
            return "上次同步 " + last.formatted(date: .omitted, time: .shortened)
        }
        return settings.didaBound ? "下拉触发同步" : "未绑定时功能照常可用"
    }

    private func addTodo() {
        let title = newTodoTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        let item = InboxItem(kind: .todo, source: .manual, rawText: title)
        item.todoTitle = title
        context.insert(item)
        try? context.save()
        newTodoTitle = ""
        // 本地待办不与滴答同步
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
    @State private var showAddSheet = false
    @State private var editingItem: InboxItem?

    private var bookmarks: [InboxItem] { items.filter { $0.kind == .bookmark } }

    private var filtered: [InboxItem] {
        switch filter {
        case .all: bookmarks
        case .tag(let tag): bookmarks.filter { $0.tags.contains(tag) }
        case .untagged: bookmarks.filter { $0.tags.isEmpty }
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
            ScreenHeader("收藏") {
                HStack(spacing: 14) {
                    Button { showAddSheet = true } label: {
                        Image(systemName: "plus")
                            .font(.title2)
                            .foregroundStyle(Theme.accent)
                            .frame(width: 34, height: 34)
                            .contentShape(Circle())
                    }
                    NavActions()
                }
            }
            List {
            if !bookmarks.isEmpty {
                tagFilterBar.carouselRow()
            }
            ForEach(filtered) { item in
                BookmarkCard(item: item,
                             onEditTags: { editingItem = item },
                             onDelete: {
                                 context.delete(item)
                                 try? context.save()
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
                                       description: Text("在任意 App 里点分享 → 选 Omny，链接和文字都能收"))
            } else if filtered.isEmpty {
                ContentUnavailableView("该标签下暂无收藏", systemImage: "tag")
            }
        }
        .sheet(isPresented: $showAddSheet) { BookmarkAddSheet() }
        .sheet(item: $editingItem) { item in
            BookmarkTagSheet(item: item)
                .presentationDetents([.medium])
        }
        }
        .background(Theme.screen)
        .toolbar(.hidden, for: .navigationBar)
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
    var onEditTags: () -> Void
    var onDelete: () -> Void

    private var url: URL? { item.urlString.flatMap(URL.init(string:)) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconChip(symbol: url != nil ? "link" : "text.alignleft", color: Theme.bookmark, size: 38)
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
        .onTapGesture {
            if let url { openURL(url) } else { onEditTags() }
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
    @State private var text = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("粘贴链接，或输入要收藏的文字…", text: $text, axis: .vertical)
                        .lineLimit(4...10)
                        .textInputAutocapitalization(.never)
                } footer: {
                    Text("带链接的会自动抽出网址和标题；配置了 LLM 时入库后自动打标。")
                }
            }
            .navigationTitle("添加收藏")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                }
            }
        }
    }

    private func save() {
        saving = true
        let content = text
        Task {
            await Ingestor.ingestBookmark(text: content, source: .manual, context: context)
            dismiss()
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
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var dida: DidaService
    @Query(filter: #Predicate<InboxItem> { $0.needsReview && !$0.deletedLocally },
           sort: \InboxItem.createdAt, order: .reverse)
    private var reviewItems: [InboxItem]

    var body: some View {
        List {
            ForEach(reviewItems) { item in
                reviewCard(item)
                    .cardCell()
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            context.delete(item)
                            try? context.save()
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
            }
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

    @ViewBuilder
    private func reviewCard(_ item: InboxItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Badge(text: item.kind == .todo ? "截图待办" : "未分类",
                      color: item.kind == .todo ? Theme.green : Theme.sub)
                Spacer()
                Text(item.createdAt.formatted(.relative(presentation: .named).locale(Locale(identifier: "zh_CN"))))
                    .font(.caption)
                    .foregroundStyle(Theme.sub)
            }
            Text(item.kind == .todo ? (item.todoTitle ?? item.rawText) : item.rawText)
                .font(.body)
                .lineLimit(4)
            if let imageData = item.sourceImage, let image = UIImage(data: imageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 90)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .opacity(0.9)
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
                }
                Button("删除", role: .destructive) {
                    context.delete(item)
                    try? context.save()
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
    }
}
