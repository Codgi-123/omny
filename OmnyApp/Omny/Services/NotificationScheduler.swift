import Foundation
import SwiftData
import UserNotifications
import OmnyCore

/// 本地通知调度：行程（前一天 + 出发前）/ 快递（每日待取数汇总）/ 待办（截止前提醒）。
/// 策略为「全量重排」：数据或设置变化后扫描全库、清掉本服务管理的挂起通知、按当前状态重排。
/// 幂等无状态，天然兜住绕过 Ingestor 的 UI 直改与滴答同步路径。
@MainActor
enum NotificationScheduler {

    // MARK: identifier 命名（重排按前缀清理，避免误删/堆积）
    // omny.trip.<uuid>.eve（前一天）/ omny.trip.<uuid>.before（出发前）/
    // omny.todo.<uuid> / omny.package.daily.<yyyyMMdd>；
    // 设置页测试通知固定 "omny.test"，不带管理前缀，不参与重排清理。
    private static let managedPrefixes = ["omny.trip.", "omny.todo.", "omny.package."]

    /// 前台横幅展示 delegate（无 delegate 时 App 在前台收不到任何提示），OmnyApp init 里挂到通知中心
    static let foregroundDelegate = ForegroundDelegate()

    final class ForegroundDelegate: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter,
                                    willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
            [.banner, .list, .sound]
        }
    }

    // MARK: 权限

    /// 申请通知权限（首次调用弹系统授权框，之后幂等）。返回是否已授权。
    static func ensureAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// 当前授权状态（设置页三态展示用：未申请 / 已拒绝 / 已授权）
    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    // MARK: 重排入口

    private static var pendingReschedule: Task<Void, Never>?

    /// 防抖重排：800ms 内的多次调用合并为一次全量重排（入库、勾选、删除等高频触发点用）
    static func requestReschedule(context: ModelContext) {
        pendingReschedule?.cancel()
        pendingReschedule = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await rescheduleAll(context: context)
        }
    }

    private static var inflightReschedule: Task<Void, Never>?

    /// 全量重排：清掉本服务管理的挂起通知 → 按当前数据与设置重排三类。
    /// App Intent 入口必须直接 await 本方法（perform 返回后进程被挂起，防抖 Task 跑不完）。
    static func rescheduleAll(context: ModelContext) async {
        // 串行化：两次重排在 await 点交错时，后者的「清理」可能跑在前者的「添加」之前，
        // 把已过期的请求重新留在挂起队列里；排队执行保证清理/添加成对不交错
        let previous = inflightReschedule
        let task = Task { @MainActor in
            await previous?.value
            await performRescheduleAll(context: context)
        }
        inflightReschedule = task
        await task.value
    }

    private static func performRescheduleAll(context: ModelContext) async {
        let center = UNUserNotificationCenter.current()
        // 未授权（或被用户关闭）时清空已排通知并返回，避免残留过期内容
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else {
            await removeManagedPending()
            return
        }

        // 自用 App 规模（几百条量级），全量拉取可接受；幂等重排换取「任何路径改数据都收敛」
        let all = (try? context.fetch(FetchDescriptor<InboxItem>())) ?? []
        await removeManagedPending()

        let settings = AppSettings.shared
        let now = Date.now
        var planned: [(fireDate: Date, request: UNNotificationRequest)] = []
        planned += tripRequests(items: all, settings: settings, now: now)
        planned += packageRequests(items: all, settings: settings, now: now)
        planned += todoRequests(items: all, settings: settings, now: now)

        // iOS 每 App 挂起通知上限 64 条：按触发时间升序只保留最近 60 条（留安全余量）
        for entry in planned.sorted(by: { $0.fireDate < $1.fireDate }).prefix(60) {
            try? await center.add(entry.request)
        }
    }

    /// 移除本服务管理的全部挂起通知（按前缀过滤，不碰 omny.test 等其他通知）
    private static func removeManagedPending() async {
        let center = UNUserNotificationCenter.current()
        let ids = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { id in managedPrefixes.contains { id.hasPrefix($0) } }
        guard !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    // MARK: 单条立即取消（UI 勾选完成/放弃/删除即时生效；随后的防抖重排兜底收敛）

    static func cancelTodoNotification(for item: InboxItem) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: ["omny.todo.\(item.id.uuidString)"])
    }

    static func cancelTripNotifications(for item: InboxItem) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [
                "omny.trip.\(item.id.uuidString).eve",
                "omny.trip.\(item.id.uuidString).before",
            ])
    }

    // MARK: 行程排期：前一天晚上 + 出发前 N 小时

    private static func tripRequests(items: [InboxItem], settings: AppSettings,
                                     now: Date) -> [(Date, UNNotificationRequest)] {
        guard settings.tripNotifyEnabled else { return [] }
        let cal = Calendar.current
        var result: [(Date, UNNotificationRequest)] = []
        for item in items.upcomingTrips(after: now) {
            guard let departAt = item.departAt else { continue }  // upcomingTrips 已保证非空，防御
            // 酒店的 departAt 是入住时间，文案用「入住」措辞
            let isHotel = item.tripKindRaw == "hotel"
            let verb = isHotel ? "入住" : "出发"
            let body = tripBody(item, departAt: departAt, verb: verb, isHotel: isHotel)

            // 前一天提醒：出发前一天的 tripEveMinutes 时刻（默认 22:00），已过去则不排
            if let eveDay = cal.date(byAdding: .day, value: -1, to: departAt),
               let eveFire = cal.date(bySettingHour: settings.tripEveMinutes / 60,
                                      minute: settings.tripEveMinutes % 60,
                                      second: 0, of: eveDay),
               eveFire > now {
                result.append((eveFire, calendarRequest(id: "omny.trip.\(item.id.uuidString).eve",
                                                        title: "明天\(verb)提醒",
                                                        body: body, fireDate: eveFire)))
            }

            // 出发前提醒：departAt 提前 tripLeadHours 小时（默认 3），已过去则不排
            let beforeFire = departAt.addingTimeInterval(-Double(settings.tripLeadHours) * 3600)
            if beforeFire > now {
                result.append((beforeFire, calendarRequest(id: "omny.trip.\(item.id.uuidString).before",
                                                           title: "\(settings.tripLeadHours) 小时后\(verb)",
                                                           body: body, fireDate: beforeFire)))
            }
        }
        return result
    }

    /// 行程通知正文：火车/航班「G59 杭州东 → 南京南，14:30 出发，检票口 A6 · 二等座」；
    /// 酒店（departPlace 存酒店名）「莫干山语·山隐民宿，14:00 入住」。
    private static func tripBody(_ item: InboxItem, departAt: Date,
                                 verb: String, isHotel: Bool) -> String {
        let time = departAt.formatted(date: .omitted, time: .shortened)
        if isHotel {
            let name = item.departPlace ?? "酒店"
            return "\(name)，\(time) \(verb)"
        }
        let route = [item.departPlace, item.arrivePlace].compactMap { $0 }.joined(separator: " → ")
        let head = [item.tripNumber, route.isEmpty ? nil : route]
            .compactMap { $0 }.joined(separator: " ")
        var body = "\(head.isEmpty ? "行程" : head)，\(time) \(verb)"
        let extras = [item.ticketGate.map { "检票口 \($0)" }, item.seatClass].compactMap { $0 }
        if !extras.isEmpty { body += "，" + extras.joined(separator: " · ") }
        return body
    }

    // MARK: 快递排期：每日待取数汇总

    /// 设计取舍：本地通知无法在触发时动态计算待取数，故用「当前待取数快照预排未来 3 天」——
    /// 取件/新入库/回前台都会触发重排刷新快照，3 天窗口限制了快照的最大过时程度。
    private static func packageRequests(items: [InboxItem], settings: AppSettings,
                                        now: Date) -> [(Date, UNNotificationRequest)] {
        guard settings.packageNotifyEnabled else { return [] }
        let waiting = items.awaitingPickupPackages()
        // 待取数 0 → 一条不排（旧通知已在重排开头统一清除，自动消失）
        guard !waiting.isEmpty else { return [] }

        // 正文：总数 + 最多 2 条明细（驿站 + 取件码），超出加「等」
        let details = waiting.prefix(2)
            .map { [$0.station, $0.pickupCode].compactMap { $0 }.joined(separator: " ") }
            .filter { !$0.isEmpty }
        var body = "你有 \(waiting.count) 件快递待取"
        if !details.isEmpty {
            body += "：" + details.joined(separator: "；")
            if waiting.count > 2 { body += " 等" }
        }

        let cal = Calendar.current
        var result: [(Date, UNNotificationRequest)] = []
        for offset in 0..<3 {
            // 今天（offset 0）仅当汇总时刻未过才排
            guard let day = cal.date(byAdding: .day, value: offset, to: now),
                  let fire = cal.date(bySettingHour: settings.packageDailyMinutes / 60,
                                      minute: settings.packageDailyMinutes % 60,
                                      second: 0, of: day),
                  fire > now else { continue }
            let id = String(format: "omny.package.daily.%04d%02d%02d",
                            cal.component(.year, from: fire),
                            cal.component(.month, from: fire),
                            cal.component(.day, from: fire))
            result.append((fire, calendarRequest(id: id, title: "待取快递",
                                                 body: body, fireDate: fire)))
        }
        return result
    }

    // MARK: 待办排期：截止前提醒

    private static func todoRequests(items: [InboxItem], settings: AppSettings,
                                     now: Date) -> [(Date, UNNotificationRequest)] {
        guard settings.todoNotifyEnabled else { return [] }
        let cal = Calendar.current
        var result: [(Date, UNNotificationRequest)] = []
        for item in items.openTodos() {
            guard let due = item.todoDue else { continue }
            // 条目级规则覆盖全局默认；-1 = 不提醒
            let minutes = item.todoReminderMinutes ?? settings.todoDefaultReminderMinutes
            guard minutes != TodoReminderRule.none.rawValue else { continue }

            // 提醒锚点：全 App 约定「00:00 = 纯日期」（见 TodoRow.dueLabel），
            // 纯日期待办按当日 9:00 提醒（与 DueDateSheet 默认时间一致），避免半夜触发
            var anchor = due
            if cal.component(.hour, from: due) == 0, cal.component(.minute, from: due) == 0 {
                anchor = cal.date(bySettingHour: 9, minute: 0, second: 0, of: due) ?? due
            }
            let fire = anchor.addingTimeInterval(-Double(minutes) * 60)
            guard fire > now else { continue }

            let title = item.todoTitle.flatMap { $0.isEmpty ? nil : $0 } ?? item.rawText
            let body = minutes == 0 ? "已到截止时间" : "\(leadLabel(minutes))后到期"
            result.append((fire, calendarRequest(id: "omny.todo.\(item.id.uuidString)",
                                                 title: title, body: body, fireDate: fire)))
        }
        return result
    }

    /// 提前量的人话格式：整天数显示「天」、整小时显示「小时」、其余「分钟」
    private static func leadLabel(_ minutes: Int) -> String {
        if minutes % 1440 == 0 { return "\(minutes / 1440) 天" }
        if minutes % 60 == 0 { return "\(minutes / 60) 小时" }
        return "\(minutes) 分钟"
    }

    // MARK: 请求组装

    /// 按具体触发时刻组装日历触发的通知请求（repeats: false，一次性）
    private static func calendarRequest(id: String, title: String, body: String,
                                        fireDate: Date) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // 必须带时区：否则触发时按设备当时时区解释组件，用户旅行换时区后行程提醒会漂移；
        // 固定为排期时区即锚定绝对时刻（回前台重排会按新时区重新计算）
        var comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute],
                                                    from: fireDate)
        comps.timeZone = Calendar.current.timeZone
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        return UNNotificationRequest(identifier: id, content: content, trigger: trigger)
    }

    // MARK: 测试通知（设置页「发送测试通知」用，2 秒后触发；id 不带管理前缀，不被重排清掉）

    static func sendTestNotification() async {
        let content = UNMutableNotificationContent()
        content.title = "Omny 测试通知"
        content.body = "通知已配置成功"
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
        let request = UNNotificationRequest(identifier: "omny.test", content: content, trigger: trigger)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
