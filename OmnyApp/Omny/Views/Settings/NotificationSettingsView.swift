import SwiftUI
import UserNotifications

/// 通知设置：行程 / 快递 / 待办三类本地通知的开关与时机（issue #16）。
/// 权限段按系统授权状态三态展示；开关/默认提醒变化立即重排，时刻类连续调整靠
/// onDisappear 的统一重排兜底（避免 DatePicker 每 tick 重排一次）。
struct NotificationSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    /// 系统授权状态（进页异步加载；申请权限/从系统设置返回后刷新）
    @State private var authStatus: UNAuthorizationStatus?

    var body: some View {
        Form {
            permissionSection
            tripSection
            packageSection
            todoSection
        }
        .navigationTitle("通知")
        .navigationBarTitleDisplayMode(.inline)
        .task { authStatus = await NotificationScheduler.authorizationStatus() }
        // 用户可能刚从系统设置改完权限回来，回前台时刷新状态
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { authStatus = await NotificationScheduler.authorizationStatus() }
            }
        }
        // 开关/默认提醒变化立即重排（关掉开关立刻清掉该类通知）
        .onChange(of: settings.tripNotifyEnabled) { _, _ in NotificationScheduler.requestReschedule(context: context) }
        .onChange(of: settings.packageNotifyEnabled) { _, _ in NotificationScheduler.requestReschedule(context: context) }
        .onChange(of: settings.todoNotifyEnabled) { _, _ in NotificationScheduler.requestReschedule(context: context) }
        .onChange(of: settings.todoDefaultReminderMinutes) { _, _ in NotificationScheduler.requestReschedule(context: context) }
        // 离开页面统一重排一次，兜住时刻/提前量的调整
        .onDisappear { NotificationScheduler.requestReschedule(context: context) }
    }

    // MARK: 权限（三态：未申请 / 已拒绝 / 已授权）

    @ViewBuilder
    private var permissionSection: some View {
        switch authStatus {
        case .notDetermined:
            Section {
                Button("申请通知权限") {
                    Task {
                        _ = await NotificationScheduler.ensureAuthorization()
                        authStatus = await NotificationScheduler.authorizationStatus()
                    }
                }
            } header: {
                Text("权限")
            } footer: {
                Text("本地通知需要系统授权，所有提醒均在设备上排期，不经过任何服务器。")
            }
        case .denied:
            Section {
                LabeledContent("通知权限") {
                    Text("已关闭").foregroundStyle(Theme.red)
                }
                Button("前往系统设置开启") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            } header: {
                Text("权限")
            } footer: {
                Text("通知权限已被关闭，需在系统设置中为 Omny 重新开启。")
            }
        case .some:   // .authorized / .provisional 等已授权态
            Section {
                LabeledContent("通知权限", value: "已开启")
                Button("发送测试通知") {
                    Task { await NotificationScheduler.sendTestNotification() }
                }
            } header: {
                Text("权限")
            } footer: {
                Text("测试通知将在 2 秒后送达（可切到后台查看横幅）。")
            }
        case nil:   // 进页异步加载中
            Section("权限") {
                LabeledContent("通知权限", value: "检查中…")
            }
        }
    }

    // MARK: 行程

    private var tripSection: some View {
        Section {
            Toggle("行程提醒", isOn: $settings.tripNotifyEnabled)
            if settings.tripNotifyEnabled {
                DatePicker("前一天提醒时刻", selection: minutesBinding($settings.tripEveMinutes),
                           displayedComponents: .hourAndMinute)
                Stepper(value: $settings.tripLeadHours, in: 1...12) {
                    LabeledContent("出发前提醒", value: "\(settings.tripLeadHours) 小时")
                }
            }
        } header: {
            Text("行程")
        } footer: {
            Text("出发前一天晚上提醒一次，当天出发前再提醒一次；酒店按入住时间计。默认 22:00 / 提前 3 小时。")
        }
    }

    // MARK: 快递

    private var packageSection: some View {
        Section {
            Toggle("快递待取提醒", isOn: $settings.packageNotifyEnabled)
            if settings.packageNotifyEnabled {
                DatePicker("每日提醒时刻", selection: minutesBinding($settings.packageDailyMinutes),
                           displayedComponents: .hourAndMinute)
            }
        } header: {
            Text("快递")
        } footer: {
            Text("每天固定时刻汇总当前待取快递数，没有待取快递时不打扰。默认 20:00。")
        }
    }

    // MARK: 待办

    private var todoSection: some View {
        Section {
            Toggle("待办到期提醒", isOn: $settings.todoNotifyEnabled)
            if settings.todoNotifyEnabled {
                Picker("默认提醒", selection: $settings.todoDefaultReminderMinutes) {
                    ForEach(TodoReminderRule.allCases) { rule in
                        Text(rule.label).tag(rule.rawValue)
                    }
                }
            }
        } header: {
            Text("待办")
        } footer: {
            Text("对未单独指定提醒的待办生效；单条待办可在编辑页「日期&提醒」里单独设置。默认提前 15 分钟。")
        }
    }

    // MARK: 分钟数 ↔ Date 转换

    /// 「当日分钟数」Int 与 DatePicker 所需 Date 的互转绑定（只取时分，日期部分无意义）
    private func minutesBinding(_ source: Binding<Int>) -> Binding<Date> {
        Binding<Date>(
            get: {
                Calendar.current.date(bySettingHour: source.wrappedValue / 60,
                                      minute: source.wrappedValue % 60, second: 0,
                                      of: Calendar.current.startOfDay(for: Date())) ?? Date()
            },
            set: { newDate in
                let c = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                source.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            }
        )
    }
}
