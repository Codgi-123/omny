import SwiftUI
import SwiftData
import OmnyCore

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var dida: DidaService
    @Query(filter: #Predicate<InboxItem> { $0.needsReview && !$0.deletedLocally })
    private var reviewItems: [InboxItem]
    // tab 选择提升为 AppStorage：首页各区块「查看详情」写同一键即可切 tab。
    // 默认值取调试初始 tab（模拟器截图用启动参数 -omnyTab N；正常首次启动为 0）。
    @AppStorage("omnySelectedTab") private var selection = DebugSupport.initialTab

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack { TodayView() }
                .tabItem { Label("今天", image: "TabToday") }
                .tag(0)
            NavigationStack { ExpressView() }
                .tabItem { Label("快递", image: "TabExpress") }
                .tag(1)
            NavigationStack { TripView() }
                .tabItem { Label("行程", image: "TabTrip") }
                .tag(2)
            NavigationStack { TodoView() }
                .tabItem { Label("待办", image: "TabTodo") }
                .badge(reviewItems.filter { $0.kind == .todo }.count)
                .tag(3)
            NavigationStack { BookmarkView() }
                .tabItem { Label("收藏", image: "TabBookmark") }
                .tag(4)
        }
        .tint(Theme.accent)
        .task {
            DebugSupport.seedIfNeeded(context)
            Trash.purgeExpired(context: context)   // 清理满 7 天的回收站条目
            // 启动时先收分享队列，再后台同步一次滴答
            await drainShareQueue()
            await dida.syncNow(context: context)
        }
        .onChange(of: scenePhase) { _, phase in
            // 从后台回到前台时自动同步（带防抖，避免频繁切换反复拉取）
            guard phase == .active else { return }
            Task {
                await drainShareQueue()
                await dida.syncOnForeground(context: context)
            }
        }
    }

    /// 收走分享扩展排队的内容：落成收藏 + LLM 打标。
    /// 图片分享（截图等）在此 OCR，文本 + 原图一起存成收藏卡片。
    private func drainShareQueue() async {
        for shared in SharedInbox.drain() {
            if let imageData = SharedInbox.imageData(for: shared) {
                let ocr = (try? await OCRService.recognizeText(in: imageData)) ?? ""
                let text = [shared.text, ocr]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                await Ingestor.ingestBookmark(text: text, urlString: shared.urlString,
                                              sourceImage: imageData, source: .share, context: context)
                SharedInbox.cleanupImage(for: shared)
            } else {
                await Ingestor.ingestBookmark(text: shared.text, urlString: shared.urlString,
                                              source: .share, context: context)
            }
        }
    }
}

// MARK: - 调试支撑（仅模拟器：灌样例数据 + 启动参数选 tab；真机永不触发）

enum DebugSupport {
    /// 用启动参数 `-omnyTab N` 指定初始 tab，方便逐屏截图自查。
    /// tab 选择改 AppStorage 持久化后，默认值只在首启生效；这里显式覆写持久键，
    /// 保证带 -omnyTab 启动时（即使模拟器里已切换过 tab）依然直达指定页。
    static var initialTab: Int {
        let tab = UserDefaults.standard.integer(forKey: "omnyTab")
        if UserDefaults.standard.object(forKey: "omnyTab") != nil {
            UserDefaults.standard.set(tab, forKey: "omnySelectedTab")
        }
        return tab
    }

    /// 仅模拟器 + 启动参数 `-omnySeed YES` + 库为空时，灌入一批展示用样例数据
    static func seedIfNeeded(_ context: ModelContext) {
        #if targetEnvironment(simulator)
        guard UserDefaults.standard.bool(forKey: "omnySeed") else { return }
        let empty = ((try? context.fetch(FetchDescriptor<InboxItem>()))?.isEmpty) ?? true
        guard empty else { return }

        func pkg(_ carrier: String, _ station: String?, _ code: String?, _ tail: String?,
                 _ status: PackageStatus, _ ageMin: Double) -> InboxItem {
            let i = InboxItem(kind: .package, source: .sms, rawText: "")
            i.carrier = carrier; i.station = station; i.pickupCode = code; i.trackingTail = tail
            i.packageStatus = status
            i.createdAt = Date().addingTimeInterval(-ageMin * 60)
            return i
        }
        func trip(_ number: String, _ kind: String, _ from: String, _ to: String,
                  _ seat: String, _ departIn: Double) -> InboxItem {
            let i = InboxItem(kind: .trip, source: .sms, rawText: "")
            i.tripNumber = number; i.tripKindRaw = kind; i.seat = seat
            i.departPlace = from; i.arrivePlace = to
            i.departAt = Date().addingTimeInterval(departIn * 3600)
            i.arriveAt = Date().addingTimeInterval((departIn + 2) * 3600)
            return i
        }
        func hotel(_ name: String, _ room: String, _ checkInHours: Double, _ nights: Double) -> InboxItem {
            let i = InboxItem(kind: .trip, source: .screenshot, rawText: "")
            i.tripKindRaw = "hotel"; i.departPlace = name; i.seat = room
            i.departAt = Date().addingTimeInterval(checkInHours * 3600)
            i.arriveAt = Date().addingTimeInterval((checkInHours + nights * 24) * 3600)
            return i
        }
        func todo(_ title: String, _ source: ItemSource, _ dueIn: Double?, _ done: Bool) -> InboxItem {
            let i = InboxItem(kind: .todo, source: source, rawText: title)
            i.todoTitle = title; i.todoCompleted = done
            if let dueIn { i.todoDue = Date().addingTimeInterval(dueIn * 3600) }
            return i
        }
        func mark(_ text: String, _ url: String?, _ title: String?, _ tags: [String]) -> InboxItem {
            let i = InboxItem(kind: .bookmark, source: .share, rawText: text)
            i.urlString = url; i.bookmarkTitle = title; i.tags = tags
            return i
        }

        [
            pkg("菜鸟驿站", "3号柜", "8-2-3021", nil, .awaitingPickup, 90),
            pkg("丰巢", "B12格口", "6612", nil, .awaitingPickup, 300),
            pkg("顺丰速运", nil, nil, "8891", .outForDelivery, 40),
            pkg("京东物流", nil, nil, "2043", .inTransit, 600),
            pkg("中通快递", "楼下超市", "5-1-08", nil, .pickedUp, 2880),
            trip("CA1831", "flight", "北京 T3", "上海 虹桥", "12A", 3.5),
            trip("G59", "train", "杭州东", "南京南", "07车09F", 28),
            trip("G7", "train", "上海虹桥", "北京南", "03车01A", -48),
            hotel("莫干山语·山隐民宿", "山景大床房", 50, 2),
            todo("买牛奶和鸡蛋", .manual, 6, false),
            todo("给妈妈打电话", .manual, nil, false),
            todo("写周报", .dida, 30, false),
            todo("预约洗牙", .dida, nil, false),
            todo("取快递", .manual, nil, true),
            mark("https://developer.apple.com/design/",
                 "https://developer.apple.com/design/", "Apple 设计资源 - HIG", ["设计", "工作"]),
            mark("SwiftUI 性能优化的几个要点，记得回头看", nil, nil, ["技术"]),
            mark("https://www.apple.com/apple-vision-pro/",
                 "https://www.apple.com/apple-vision-pro/", "Apple Vision Pro", ["硬件"]),
        ].forEach { context.insert($0) }

        let review = InboxItem(kind: .todo, source: .screenshot, rawText: "周五下午三点产品评审会")
        review.todoTitle = "周五下午三点产品评审会"
        review.needsReview = true
        context.insert(review)

        try? context.save()
        #endif
    }
}

/// 导航栏右侧：需修正入口 + 设置入口
struct NavActions: View {
    @Query(filter: #Predicate<InboxItem> { $0.needsReview && !$0.deletedLocally })
    private var reviewItems: [InboxItem]

    var body: some View {
        HStack(spacing: 14) {
            if !reviewItems.isEmpty {
                NavigationLink {
                    ReviewView()
                } label: {
                    Image(systemName: "exclamationmark.circle")
                        .font(.title2)
                        .foregroundStyle(Theme.accent)
                        .frame(width: 34, height: 34)
                        .contentShape(Circle())
                }
            }
            NavigationLink {
                SettingsView()
            } label: {
                Image(systemName: "gearshape")
                    .font(.title2)
                    .foregroundStyle(Theme.sub)
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
            }
        }
    }
}
