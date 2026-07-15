import SwiftUI
import SwiftData
import OmnyCore

/// 底部 tab 的稳定标识符（issue #10：快递+行程合并为「包裹·行程」，腾出的位置给记账）。
/// rawValue 持久化进 AppStorage（"omnySelectedTab"）。旧版语义为 0今天/1快递/2行程/3待办/4收藏：
/// 旧 1(快递) 恰落新 1(包裹·行程)，3/4 含义不变；旧 2(行程) 首启会落到新 2(记账) 一次，可接受。
/// 越界的历史/异常整数值由 RawRepresentable 解码失败自动回落默认「今天」。
enum RootTab: Int, CaseIterable {
    case today = 0        // 今天
    case packageTrip = 1  // 包裹·行程（内部分段见 PackageTripView.Segment）
    case expense = 2      // 记账
    case todo = 3         // 待办
    case bookmark = 4     // 收藏
}

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var dida: DidaService
    @Query(filter: InboxItem.needsReviewPredicate)
    private var reviewItems: [InboxItem]
    // tab 选择提升为 AppStorage：首页各区块「查看详情」写同一键即可切 tab。
    // 默认值取调试初始 tab（模拟器截图用启动参数 -omnyTab N；正常首次启动为今天页）。
    @AppStorage("omnySelectedTab") private var selection = DebugSupport.initialTab
    // 每个 tab 各自的导航栈路径：需处理/设置走值驱动 push，切 tab 时统一弹回根部，
    // 避免这两个全局页面残留在多个 tab 的栈里（issue #9）。
    @State private var tabPaths: [NavigationPath] = Array(repeating: NavigationPath(), count: 5)

    var body: some View {
        TabView(selection: $selection) {
            RootTabStack(path: $tabPaths[0]) { TodayView() }
                .tabItem { Label("今天", image: "TabToday") }
                .tag(RootTab.today)
            RootTabStack(path: $tabPaths[1]) { PackageTripView() }
                .tabItem { Label("包裹·行程", image: "TabPackageTrip") }
                .tag(RootTab.packageTrip)
            RootTabStack(path: $tabPaths[2]) { ExpenseHomeView() }
                .tabItem { Label("记账", image: "TabExpense") }
                .tag(RootTab.expense)
            RootTabStack(path: $tabPaths[3]) { TodoView() }
                .tabItem { Label("待办", image: "TabTodo") }
                .badge(reviewItems.filter { $0.kind == .todo }.count)
                .tag(RootTab.todo)
            RootTabStack(path: $tabPaths[4]) { BookmarkView() }
                .tabItem { Label("收藏", image: "TabBookmark") }
                .tag(RootTab.bookmark)
        }
        .tint(Theme.accent)
        .onChange(of: selection) { _, _ in
            // 切 tab 时把所有 tab 的导航栈弹回根部：
            // 需处理/设置是独立页面，不该在切走再切回后仍停留在某个 tab 里
            for i in tabPaths.indices where !tabPaths[i].isEmpty {
                tabPaths[i] = NavigationPath()
            }
        }
        .task {
            DebugSupport.seedIfNeeded(context)
            Trash.purgeExpired(context: context)   // 清理满保留期（默认 7 天，高级设置可调）的回收站条目
            // 启动时先收分享队列，再后台同步一次滴答
            await drainShareQueue()
            await dida.syncNow(context: context)
            // 通知：启动申请权限（首次弹框，之后幂等）+ 全量重排
            _ = await NotificationScheduler.ensureAuthorization()
            NotificationScheduler.requestReschedule(context: context)
        }
        .onChange(of: scenePhase) { _, phase in
            // 从后台回到前台时自动同步（带防抖，避免频繁切换反复拉取）
            guard phase == .active else { return }
            Task {
                await drainShareQueue()
                await dida.syncOnForeground(context: context)
                // 滴答同步完成后重排通知（覆盖远端完成/删除待办的变更）
                NotificationScheduler.requestReschedule(context: context)
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
    /// N 按 RootTab 的 rawValue：0 今天 / 1 包裹·行程 / 2 记账 / 3 待办 / 4 收藏。
    /// tab 选择改 AppStorage 持久化后，默认值只在首启生效；这里显式覆写持久键，
    /// 保证带 -omnyTab 启动时（即使模拟器里已切换过 tab）依然直达指定页。
    /// 越界的 N 回落「今天」。
    static var initialTab: RootTab {
        let tab = RootTab(rawValue: UserDefaults.standard.integer(forKey: "omnyTab")) ?? .today
        if UserDefaults.standard.object(forKey: "omnyTab") != nil {
            UserDefaults.standard.set(tab.rawValue, forKey: "omnySelectedTab")
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
                  _ seat: String, _ departIn: Double,
                  gate: String? = nil, seatClass: String? = nil) -> InboxItem {
            let i = InboxItem(kind: .trip, source: .sms, rawText: "")
            i.tripNumber = number; i.tripKindRaw = kind; i.seat = seat
            i.ticketGate = gate; i.seatClass = seatClass
            i.departPlace = from; i.arrivePlace = to
            i.departAt = Date().addingTimeInterval(departIn * 3600)
            i.arriveAt = Date().addingTimeInterval((departIn + 2) * 3600)
            return i
        }
        func hotel(_ name: String, _ room: String, _ checkInHours: Double, _ nights: Double,
                   address: String? = nil) -> InboxItem {
            let i = InboxItem(kind: .trip, source: .screenshot, rawText: "")
            i.tripKindRaw = "hotel"; i.departPlace = name; i.seat = room
            i.tripAddress = address
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
            trip("G59", "train", "杭州东", "南京南", "07车09F号", 28, gate: "A6", seatClass: "二等座"),
            trip("G7", "train", "上海虹桥", "北京南", "03车01A号", -48, gate: "B12", seatClass: "一等座"),
            hotel("莫干山语·山隐民宿", "山景大床房 · 含双早", 50, 2, address: "德清县莫干山镇劳岭村108号"),
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

// MARK: - 导航栈与全局入口

/// NavActions 的导航目的地（值驱动，push 记录进 NavigationPath，切 tab 时才能统一弹回）
enum RootDestination: Hashable {
    case review    // 需处理
    case settings  // 设置
}

/// 单个 tab 的导航栈：绑定各自的 path，并在根视图上注册 RootDestination 的目的地。
/// 注册点放在每个栈的根视图层级，避免子视图重复注册告警。
private struct RootTabStack<Content: View>: View {
    @Binding var path: NavigationPath
    @ViewBuilder let content: () -> Content

    var body: some View {
        NavigationStack(path: $path) {
            content()
                .navigationDestination(for: RootDestination.self) { destination in
                    switch destination {
                    case .review: ReviewView()
                    case .settings: SettingsView()
                    }
                }
        }
    }
}

/// 导航栏右侧：需修正入口 + 设置入口
struct NavActions: View {
    @Query(filter: InboxItem.needsReviewPredicate)
    private var reviewItems: [InboxItem]

    var body: some View {
        HStack(spacing: 14) {
            if !reviewItems.isEmpty {
                NavigationLink(value: RootDestination.review) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.title2)
                        .foregroundStyle(Theme.accent)
                        .frame(width: 34, height: 34)
                        .contentShape(Circle())
                }
            }
            NavigationLink(value: RootDestination.settings) {
                Image(systemName: "gearshape")
                    .font(.title2)
                    .foregroundStyle(Theme.sub)
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
            }
        }
    }
}
