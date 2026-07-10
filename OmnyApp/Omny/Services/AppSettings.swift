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
        return LLMConfig(apiProtocol: llmProtocol, baseURL: url, apiKey: llmAPIKey, model: llmModel)
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

    private init() {
        llmProtocol = LLMProtocol(rawValue: defaults.string(forKey: "llm.protocol") ?? "") ?? .claude
        llmBaseURL = defaults.string(forKey: "llm.baseURL") ?? "https://api.anthropic.com"
        llmAPIKey = defaults.string(forKey: "llm.apiKey") ?? ""
        llmModel = defaults.string(forKey: "llm.model") ?? "claude-opus-4-8"
        bookmarkTags = defaults.stringArray(forKey: "bookmark.tags") ?? Self.defaultBookmarkTags
        didaAccessToken = defaults.string(forKey: "dida.accessToken")
        didaProjectID = defaults.string(forKey: "dida.projectID")
        didaProjectName = defaults.string(forKey: "dida.projectName")
        didaLastSync = defaults.object(forKey: "dida.lastSync") as? Date
        autoAddToCalendar = defaults.object(forKey: "trip.autoCalendar") as? Bool ?? true
    }

    /// 恢复出厂：LLM 配置、滴答绑定、收藏标签全部重置为默认。
    /// （不含条目数据——那由 DataMaintenance 清 SwiftData。）赋值经各自 didSet 落回 UserDefaults。
    func resetToDefaults() {
        llmProtocol = .claude
        llmBaseURL = "https://api.anthropic.com"
        llmAPIKey = ""
        llmModel = "claude-opus-4-8"
        bookmarkTags = Self.defaultBookmarkTags
        didaAccessToken = nil
        didaProjectID = nil
        didaProjectName = nil
        didaLastSync = nil
        autoAddToCalendar = true
    }
}
