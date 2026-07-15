import Foundation
import OmnyCore

/// 运行时配置。v1 用 UserDefaults 存（含密钥，自用可接受；后续可迁 Keychain）。
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    // MARK: 滴答应用身份（应用级常量，值在 Secrets.swift，不入库）

    static let didaClientID = Secrets.didaClientID
    static let didaClientSecret = Secrets.didaClientSecret
    static let didaRedirectURI = Secrets.didaRedirectURI

    // MARK: LLM 配置（协议 / Base URL / Key / 模型全部可改）

    @Published var llmProtocol: LLMProtocol {
        didSet { defaults.set(llmProtocol.rawValue, forKey: "llm.protocol") }
    }
    @Published var llmBaseURL: String {
        didSet { defaults.set(llmBaseURL, forKey: "llm.baseURL") }
    }
    @Published var llmAPIKey: String {
        didSet { defaults.set(llmAPIKey, forKey: "llm.apiKey") }
    }
    @Published var llmModel: String {
        didSet { defaults.set(llmModel, forKey: "llm.model") }
    }

    var llmConfig: LLMConfig? {
        guard !llmAPIKey.isEmpty, let url = URL(string: llmBaseURL) else { return nil }
        return LLMConfig(apiProtocol: llmProtocol, baseURL: url, apiKey: llmAPIKey, model: llmModel,
                         maxTokens: llmMaxTokens, timeout: llmTimeoutSeconds)
    }

    /// 解析管线：配了 LLM 就"分类靠正则、结构化靠 LLM"（快递/行程走 LLM 抽字段），
    /// 兜底仍用 LLMTodoParser 抽自由文本里的待办；没配 LLM 则纯规则降级。
    var parserPipeline: ParserPipeline {
        guard let llmConfig else {
            return ParserPipeline(primary: RuleParser())
        }
        return ParserPipeline(primary: LLMStructuredParser(config: llmConfig),
                              fallback: LLMTodoParser(config: llmConfig))
    }

    /// 截图 OCR 专用解析器：一屏多条多类一次抽取（快递/行程/待办），忽略噪声。
    /// 未配 LLM 时 ScreenParser 内部按行走规则降级，故 config 传 nil 也可用。
    var screenParser: ScreenParser {
        ScreenParser(config: llmConfig)
    }

    // MARK: 收藏 tag（预置一批，设置页可增删改；LLM 打标只从这里选）

    static let defaultBookmarkTags = ["技术", "资讯", "视频", "购物", "美食", "旅行", "灵感", "工具", "娱乐"]

    @Published var bookmarkTags: [String] {
        didSet { defaults.set(bookmarkTags, forKey: "bookmark.tags") }
    }

    /// 标签候选列表 = 配置池 + 已用值合并：存量条目上已有、但池里已被删掉/改名的旧标签
    /// 不吞掉（追加在池后，保持出现顺序）。收藏筛选栏、标签编辑、收藏详情共用这一套合并规则。
    func mergedTagCandidates(including used: [String]) -> [String] {
        var tags = bookmarkTags
        for tag in used where !tags.contains(tag) { tags.append(tag) }
        return tags
    }

    // MARK: 消费分类池（两级：大类 → 细分；LLM 打标只从这里选，扁平化成"大类/细分"约束）

    static let defaultExpenseCategoryPool: [String: [String]] = [
        "餐饮": ["早餐", "午餐", "晚餐", "外卖", "咖啡零食"],
        "交通": ["打车", "公交地铁", "加油", "停车"],
        "购物": ["日用", "服饰", "数码", "家居"],
        "居家": ["房租", "水电燃气", "物业"],
        "娱乐": ["订阅", "游戏", "电影"],
        "医疗": ["门诊", "药品"],
        "收入": ["工资", "报销", "退款", "其他"],
    ]

    /// 两级分类池。UserDefaults 存 JSON（字典嵌套数组无法直接存）。
    @Published var expenseCategoryPool: [String: [String]] {
        didSet {
            if let data = try? JSONEncoder().encode(expenseCategoryPool) {
                defaults.set(data, forKey: "expense.categoryPool")
            }
        }
    }

    /// 记账消费分类器（LLM 配好才有）
    var expenseCategorizer: LLMExpenseCategorizer? {
        llmConfig.map { LLMExpenseCategorizer(config: $0) }
    }

    // MARK: 滴答清单绑定状态

    @Published var didaAccessToken: String? {
        didSet { defaults.set(didaAccessToken, forKey: "dida.accessToken") }
    }
    @Published var didaProjectID: String? {
        didSet { defaults.set(didaProjectID, forKey: "dida.projectID") }
    }
    @Published var didaProjectName: String? {
        didSet { defaults.set(didaProjectName, forKey: "dida.projectName") }
    }
    @Published var didaLastSync: Date? {
        didSet { defaults.set(didaLastSync, forKey: "dida.lastSync") }
    }

    var didaBound: Bool { didaAccessToken != nil && didaProjectID != nil }

    // MARK: 行程日历

    @Published var autoAddToCalendar: Bool {
        didSet { defaults.set(autoAddToCalendar, forKey: "trip.autoCalendar") }
    }

    // MARK: 通知（issue #16：行程/快递/待办三类本地通知；时刻用当日分钟数存，避免 Date 带日期歧义）

    /// 行程提醒开关。默认开。
    @Published var tripNotifyEnabled: Bool {
        didSet { defaults.set(tripNotifyEnabled, forKey: "notify.trip.enabled") }
    }
    /// 行程前一天提醒时刻（当日分钟数，默认 1320 = 22:00）。
    @Published var tripEveMinutes: Int {
        didSet { defaults.set(tripEveMinutes, forKey: "notify.trip.eveMinutes") }
    }
    /// 行程出发前提前量（小时，默认 3）。
    @Published var tripLeadHours: Int {
        didSet { defaults.set(tripLeadHours, forKey: "notify.trip.leadHours") }
    }
    /// 快递每日待取汇总开关。默认开。
    @Published var packageNotifyEnabled: Bool {
        didSet { defaults.set(packageNotifyEnabled, forKey: "notify.package.enabled") }
    }
    /// 快递每日汇总时刻（当日分钟数，默认 1200 = 20:00）。
    @Published var packageDailyMinutes: Int {
        didSet { defaults.set(packageDailyMinutes, forKey: "notify.package.dailyMinutes") }
    }
    /// 待办到期提醒开关。默认开。
    @Published var todoNotifyEnabled: Bool {
        didSet { defaults.set(todoNotifyEnabled, forKey: "notify.todo.enabled") }
    }
    /// 待办默认提醒规则（TodoReminderRule.rawValue，默认 15 = 提前 15 分钟；-1 不提醒）。
    /// 单条待办可用 InboxItem.todoReminderMinutes 覆盖。
    @Published var todoDefaultReminderMinutes: Int {
        didSet { defaults.set(todoDefaultReminderMinutes, forKey: "notify.todo.defaultReminderMinutes") }
    }

    // MARK: 高级设置（低频参数；默认值 = 原硬编码值，语义不变。入口：设置 → 高级设置）

    /// 解析低置信度阈值：解析置信度低于该值的条目标记 needsReview 进「需处理」。默认 0.8。
    @Published var lowConfidenceThreshold: Double {
        didSet { defaults.set(lowConfidenceThreshold, forKey: "parsing.lowConfidenceThreshold") }
    }
    /// 截图识别出的待办是否直接入库。默认关（先进「需处理」等用户确认）。
    @Published var screenshotTodoDirectIngest: Bool {
        didSet { defaults.set(screenshotTodoDirectIngest, forKey: "parsing.screenshotTodoDirectIngest") }
    }
    /// 记账模糊去重的时间窗（分钟，±）。默认 10。
    @Published var expenseDedupWindowMinutes: Int {
        didSet { defaults.set(expenseDedupWindowMinutes, forKey: "expense.dedupWindowMinutes") }
    }
    /// 滴答前台同步的最小间隔（秒），防抖用。默认 30。
    @Published var didaForegroundSyncMinInterval: Double {
        didSet { defaults.set(didaForegroundSyncMinInterval, forKey: "dida.foregroundSyncMinInterval") }
    }
    /// 航班动态 MCP 缓存有效期（分钟）。默认 10。
    @Published var flightCacheTTLMinutes: Int {
        didSet { defaults.set(flightCacheTTLMinutes, forKey: "flight.cacheTTLMinutes") }
    }
    /// 回收站保留天数，满期彻底删除。默认 7。
    /// 注意：`InboxItem.trashRetentionDays` 直接读同一个 UserDefaults 键
    /// （SwiftData 模型层非 MainActor，拿不到本类实例），改键名要两处同步。
    @Published var trashRetentionDays: Int {
        didSet { defaults.set(trashRetentionDays, forKey: "data.trashRetentionDays") }
    }
    /// LLM 输出 token 上限（结构化抽取等大输出任务的兜底值；打标/分类小任务不受影响）。默认 2048。
    @Published var llmMaxTokens: Int {
        didSet { defaults.set(llmMaxTokens, forKey: "llm.maxTokens") }
    }
    /// LLM 单次请求超时（秒）。默认 60。
    @Published var llmTimeoutSeconds: Double {
        didSet { defaults.set(llmTimeoutSeconds, forKey: "llm.timeoutSeconds") }
    }

    private init() {
        llmProtocol = LLMProtocol(rawValue: defaults.string(forKey: "llm.protocol") ?? "") ?? .claude
        llmBaseURL = defaults.string(forKey: "llm.baseURL") ?? "https://api.anthropic.com"
        llmAPIKey = defaults.string(forKey: "llm.apiKey") ?? ""
        llmModel = defaults.string(forKey: "llm.model") ?? "claude-opus-4-8"
        bookmarkTags = defaults.stringArray(forKey: "bookmark.tags") ?? Self.defaultBookmarkTags
        if let data = defaults.data(forKey: "expense.categoryPool"),
           let pool = try? JSONDecoder().decode([String: [String]].self, from: data) {
            expenseCategoryPool = pool
        } else {
            expenseCategoryPool = Self.defaultExpenseCategoryPool
        }
        didaAccessToken = defaults.string(forKey: "dida.accessToken")
        didaProjectID = defaults.string(forKey: "dida.projectID")
        didaProjectName = defaults.string(forKey: "dida.projectName")
        didaLastSync = defaults.object(forKey: "dida.lastSync") as? Date
        autoAddToCalendar = defaults.object(forKey: "trip.autoCalendar") as? Bool ?? true
        tripNotifyEnabled = defaults.object(forKey: "notify.trip.enabled") as? Bool ?? true
        tripEveMinutes = defaults.object(forKey: "notify.trip.eveMinutes") as? Int ?? 1320
        tripLeadHours = defaults.object(forKey: "notify.trip.leadHours") as? Int ?? 3
        packageNotifyEnabled = defaults.object(forKey: "notify.package.enabled") as? Bool ?? true
        packageDailyMinutes = defaults.object(forKey: "notify.package.dailyMinutes") as? Int ?? 1200
        todoNotifyEnabled = defaults.object(forKey: "notify.todo.enabled") as? Bool ?? true
        todoDefaultReminderMinutes = defaults.object(forKey: "notify.todo.defaultReminderMinutes") as? Int ?? TodoReminderRule.before15m.rawValue
        lowConfidenceThreshold = defaults.object(forKey: "parsing.lowConfidenceThreshold") as? Double ?? 0.8
        screenshotTodoDirectIngest = defaults.object(forKey: "parsing.screenshotTodoDirectIngest") as? Bool ?? false
        expenseDedupWindowMinutes = defaults.object(forKey: "expense.dedupWindowMinutes") as? Int ?? 10
        didaForegroundSyncMinInterval = defaults.object(forKey: "dida.foregroundSyncMinInterval") as? Double ?? 30
        flightCacheTTLMinutes = defaults.object(forKey: "flight.cacheTTLMinutes") as? Int ?? 10
        trashRetentionDays = defaults.object(forKey: "data.trashRetentionDays") as? Int ?? 7
        llmMaxTokens = defaults.object(forKey: "llm.maxTokens") as? Int ?? 2048
        llmTimeoutSeconds = defaults.object(forKey: "llm.timeoutSeconds") as? Double ?? 60
    }

    /// 恢复出厂：LLM 配置、滴答绑定、收藏标签全部重置为默认。
    /// （不含条目数据——那由 DataMaintenance 清 SwiftData。）赋值经各自 didSet 落回 UserDefaults。
    func resetToDefaults() {
        llmProtocol = .claude
        llmBaseURL = "https://api.anthropic.com"
        llmAPIKey = ""
        llmModel = "claude-opus-4-8"
        bookmarkTags = Self.defaultBookmarkTags
        expenseCategoryPool = Self.defaultExpenseCategoryPool
        didaAccessToken = nil
        didaProjectID = nil
        didaProjectName = nil
        didaLastSync = nil
        autoAddToCalendar = true
        tripNotifyEnabled = true
        tripEveMinutes = 1320
        tripLeadHours = 3
        packageNotifyEnabled = true
        packageDailyMinutes = 1200
        todoNotifyEnabled = true
        todoDefaultReminderMinutes = TodoReminderRule.before15m.rawValue
        lowConfidenceThreshold = 0.8
        screenshotTodoDirectIngest = false
        expenseDedupWindowMinutes = 10
        didaForegroundSyncMinInterval = 30
        flightCacheTTLMinutes = 10
        trashRetentionDays = 7
        llmMaxTokens = 2048
        llmTimeoutSeconds = 60
    }
}
