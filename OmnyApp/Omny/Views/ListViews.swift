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
        .refreshable { await dida.syncNow(context: context) }
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

// MARK: - 收藏页

struct BookmarkView: View {
    @Query(sort: \InboxItem.createdAt, order: .reverse) private var items: [InboxItem]

    private var bookmarks: [InboxItem] { items.filter { $0.kind == .bookmark } }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if bookmarks.isEmpty {
                    ContentUnavailableView("暂无收藏", systemImage: "bookmark",
                                           description: Text("在任意 App 里分享链接给 Omny"))
                        .padding(.top, 80)
                }
                ForEach(bookmarks) { item in
                    Link(destination: URL(string: item.urlString ?? "") ?? URL(string: "https://example.com")!) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(item.bookmarkTitle ?? "链接")
                                    .font(.system(size: 14.5, weight: .bold))
                                    .foregroundStyle(Theme.text)
                                    .lineLimit(2)
                                Spacer()
                                Badge(text: "链接", color: Theme.accent)
                            }
                            Text(URL(string: item.urlString ?? "")?.host() ?? item.urlString ?? "")
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.sub)
                        }
                        .cardStyle()
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Theme.screen)
        .navigationTitle("收藏")
        .toolbar { NavActions() }
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
        ScrollView {
            LazyVStack(spacing: 10) {
                if reviewItems.isEmpty {
                    ContentUnavailableView("没有需要处理的内容", systemImage: "checkmark.seal")
                        .padding(.top, 80)
                }
                ForEach(reviewItems) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Badge(text: item.kind == .todo ? "截图待办" : "未分类",
                                  color: item.kind == .todo ? Theme.green : Theme.sub)
                            Spacer()
                            Text(item.createdAt.formatted(.relative(presentation: .named)))
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.sub)
                        }
                        Text(item.kind == .todo ? (item.todoTitle ?? item.rawText) : item.rawText)
                            .font(.system(size: 14.5, weight: item.kind == .todo ? .bold : .regular))
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
                    }
                    .cardStyle()
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Theme.screen)
        .navigationTitle("需处理")
    }
}
