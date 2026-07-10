import SwiftUI
import SwiftData
import OmnyCore

// MARK: - 快递页：待取 / 在途 / 已签收

struct ExpressView: View {
    @Query(sort: \InboxItem.createdAt, order: .reverse) private var items: [InboxItem]

    private var packages: [InboxItem] { items.filter { $0.kind == .package } }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                group("待取", packages.filter { $0.packageStatus == .awaitingPickup })
                group("在途", packages.filter { $0.packageStatus < .awaitingPickup })
                group("已签收", packages.filter { $0.packageStatus == .pickedUp }, dimmed: true)
                if packages.isEmpty {
                    ContentUnavailableView("暂无快递", systemImage: "shippingbox",
                                           description: Text("驿站短信到达后会自动出现在这里"))
                        .padding(.top, 80)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Theme.screen)
        .navigationTitle("快递")
        .toolbar { NavActions() }
    }

    @ViewBuilder
    private func group(_ title: String, _ list: [InboxItem], dimmed: Bool = false) -> some View {
        if !list.isEmpty {
            Text(title)
                .font(.system(size: 12, weight: .heavy))
                .foregroundStyle(Theme.sub)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.top, 14)
            ForEach(list) { PackageCard(item: $0).opacity(dimmed ? 0.62 : 1) }
        }
    }
}

// MARK: - 行程页：即将出行 / 历史

struct TripView: View {
    @Environment(\.modelContext) private var context
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
        ScrollView {
            LazyVStack(spacing: 10) {
                if upcoming.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "tram")
                            .font(.system(size: 36))
                            .foregroundStyle(Theme.sub.opacity(0.7))
                        Text("暂无即将出行")
                            .font(.system(size: 15, weight: .bold))
                        Text("购票短信会自动生成行程卡片")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.sub)
                    }
                    .padding(.vertical, 60)
                } else {
                    sectionTitle("即将出行")
                    ForEach(upcoming) { TripCard(item: $0) }
                }
                if !past.isEmpty {
                    sectionTitle("历史行程")
                    ForEach(past) { item in
                        HStack {
                            Text("\(item.tripNumber ?? "") \(item.departPlace ?? "") → \(item.arrivePlace ?? "")")
                                .font(.system(size: 14.5, weight: .bold))
                            Spacer()
                            Badge(text: "已结束")
                        }
                        .cardStyle()
                        .opacity(0.62)
                        .contextMenu {
                            Button(role: .destructive) {
                                context.delete(item)
                                try? context.save()
                            } label: { Label("删除", systemImage: "trash") }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Theme.screen)
        .navigationTitle("行程")
        .toolbar { NavActions() }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .heavy))
            .foregroundStyle(Theme.sub)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.top, 14)
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
        ScrollView {
            LazyVStack(spacing: 10) {
                syncBanner
                HStack(spacing: 8) {
                    TextField("添加待办…", text: $newTodoTitle)
                        .textFieldStyle(.plain)
                        .onSubmit(addTodo)
                    Button(action: addTodo) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(Theme.accent)
                            .font(.system(size: 22))
                    }
                    .buttonStyle(.plain)
                }
                .cardStyle()

                ForEach(todos.filter { !$0.todoCompleted }) { TodoRow(item: $0) }

                let done = todos.filter(\.todoCompleted)
                if !done.isEmpty {
                    Text("已完成")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(Theme.sub)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .padding(.top, 14)
                    ForEach(done) { TodoRow(item: $0).opacity(0.62) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Theme.screen)
        .navigationTitle("待办")
        .toolbar { NavActions() }
        // 包一层非结构化 Task：.refreshable 的任务绑定在刷新手势上，视图刷新时会被
        // SwiftUI 取消并把取消传给 URLSession（表现为"同步失败：cancelled"）。
        // Task {} 不继承外层取消，await .value 让菊花转到同步真正结束。
        .refreshable { await Task { await dida.syncNow(context: context) }.value }
    }

    private var syncBanner: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(settings.didaBound ? "滴答清单 · \(settings.didaProjectName ?? "")" : "滴答清单未绑定")
                    .font(.system(size: 14.5, weight: .bold))
                Text(bannerDetail)
                    .font(.system(size: 12))
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
        .padding(13)
        .background(Theme.slate.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Theme.slate.opacity(0.2)))
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
        ScrollView {
            LazyVStack(spacing: 10) {
                if !bookmarks.isEmpty { tagFilterBar }
                if bookmarks.isEmpty {
                    ContentUnavailableView("暂无收藏", systemImage: "bookmark",
                                           description: Text("在任意 App 里点分享 → 选 Omny，链接和文字都能收"))
                        .padding(.top, 80)
                } else if filtered.isEmpty {
                    ContentUnavailableView("该标签下暂无收藏", systemImage: "tag")
                        .padding(.top, 60)
                }
                ForEach(filtered) { item in
                    BookmarkCard(item: item,
                                 onEditTags: { editingItem = item },
                                 onDelete: {
                                     context.delete(item)
                                     try? context.save()
                                 })
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Theme.screen)
        .navigationTitle("收藏")
        .toolbar {
            HStack(spacing: 8) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(Theme.accent)
                }
                NavActions()
            }
        }
        .sheet(isPresented: $showAddSheet) { BookmarkAddSheet() }
        .sheet(item: $editingItem) { item in
            BookmarkTagSheet(item: item)
                .presentationDetents([.medium])
        }
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
            .padding(.horizontal, 2)
            .padding(.vertical, 4)
        }
    }

    private func filterChip(_ label: String, _ value: TagFilter) -> some View {
        let selected = filter == value
        return Button {
            filter = value
        } label: {
            Text(label)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(selected ? Theme.card : Theme.sub)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selected ? Theme.accent : Theme.card)
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Theme.line, lineWidth: selected ? 0 : 1))
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(title)
                    .font(.system(size: 14.5, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer()
                Badge(text: url != nil ? "链接" : "文本",
                      color: url != nil ? Theme.accent : Theme.slate)
            }
            if let url {
                Text(url.host() ?? url.absoluteString)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.sub)
                    .lineLimit(1)
            } else if item.rawText != title {
                Text(item.rawText)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.sub)
                    .lineLimit(3)
            }
            HStack(spacing: 6) {
                if item.tags.isEmpty {
                    Text("未打标")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.sub.opacity(0.7))
                } else {
                    ForEach(item.tags, id: \.self) { Badge(text: $0, color: Theme.green) }
                }
                Spacer()
                Text(item.createdAt.formatted(.relative(presentation: .named)))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.sub)
            }
        }
        .cardStyle()
        .contentShape(Rectangle())
        .onTapGesture {
            if let url { openURL(url) } else { onEditTags() }
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
    @Query(filter: #Predicate<InboxItem> { $0.needsReview && !$0.deletedLocally },
           sort: \InboxItem.createdAt, order: .reverse)
    private var reviewItems: [InboxItem]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if reviewItems.isEmpty {
                    ContentUnavailableView("没有需要处理的内容", systemImage: "checkmark.seal")
                        .padding(.top, 80)
                }
                ForEach(reviewItems) { item in
                    ReviewCard(item: item)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Theme.screen)
        .navigationTitle("需处理")
    }
}

/// 需处理单条卡片：点击正文可展开/收起全文（默认截断，长文本给提示）。
private struct ReviewCard: View {
    @Bindable var item: InboxItem
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var dida: DidaService
    @State private var expanded = false

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
        }
        .cardStyle()
    }
}
