import AppIntents
import SwiftData
import SwiftUI
import OmnyCore

/// 快捷指令动作 ①：解析文本（短信自动化用）
/// 自动化：收到信息 → 运行本动作（输入 = 信息内容），无感入库。
/// 「直接入库」开关（默认开）：开=当前节点入库（原行为不变）；
/// 关=只解析不落库，输出 [InboxItemEntity] 给下游（如「确认记账」）先核对再入库。
struct ParseTextIntent: AppIntent {
    static let title: LocalizedStringResource = "解析文本"
    static let description = IntentDescription("把短信或任意文本交给 Omny 解析入库（快递、行程、待办、记账）。")
    static let openAppWhenRun = false

    @Parameter(title: "文本")
    var text: String

    @Parameter(title: "直接入库", description: "开：直接入库（默认）；关：只解析输出，交给后续「确认记账」等动作再入库。",
               default: true)
    var autoIngest: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[InboxItemEntity]> & ProvidesDialog {
        // 解析文本通道只过滤收藏；快递/行程/待办/记账（含会议通知、动账短信等）都入库
        let allowed: Set<ItemType> = [.package, .trip, .todo, .expense]

        if autoIngest {
            // 直接入库：走现有 Ingestor.ingest（解析+入库一体）。
            // awaitEnrichment：App Intent perform 返回后进程会挂起，必须同步等记账分类/收藏打标补完
            let items = await Ingestor.ingest(text: text, source: .sms,
                                              allowedTypes: allowed,
                                              awaitEnrichment: true, context: OmnyApp.sharedModelContainer.mainContext)
            guard !items.isEmpty else {
                return .result(value: [], dialog: "没有识别到快递、行程、待办或记账")
            }
            let summary = items.map(\.intentSummary).joined(separator: "；")
            return .result(value: [], dialog: IntentDialog(stringLiteral: "已入库：\(summary)"))
        }

        // 只解析不入库：直接调解析管线，转成实体输出给下游
        let entities = await Self.parseToEntities(text, parser: AppSettings.shared.parserPipeline,
                                                  allowed: allowed)
        guard !entities.isEmpty else {
            return .result(value: [], dialog: "没有识别到快递、行程、待办或记账")
        }
        let summary = entities.map(\.intentSummary).joined(separator: "；")
        return .result(value: entities, dialog: IntentDialog(stringLiteral: "已解析 \(entities.count) 条：\(summary)"))
    }

    /// 只解析（不落库）→ 实体数组。allowed 为空表示不过滤类型。
    @MainActor
    static func parseToEntities(_ text: String, parser: any Parser,
                                allowed: Set<ItemType>? = nil) async -> [InboxItemEntity] {
        guard let result = try? await parser.parse(text) else { return [] }
        var payloads = result.payload.flattened
        if let allowed { payloads = payloads.filter { allowed.contains($0.itemType) } }
        // 带上原文：确认阶段补分类要靠原文喂 LLM（口语句子常无独立商户名）
        return InboxItemEntity.from(payloads: payloads, rawText: text)
    }
}

/// 快捷指令动作 ②：屏幕识别（截屏 → 快捷指令内置 OCR → 文本传入）
/// iOS 快捷指令自带「识别图像文本」动作，OCR 在快捷指令侧完成，本动作直接收文本，
/// 走截图专用解析器 ScreenParser（一屏多条多类：快递/行程/待办/记账），按识别结果落到对应分类。
/// 收藏不作为截图识别目标（截图里的链接少见且噪声多，收藏走分享面板入口）。
/// 「直接入库」开关同「解析文本」：开=直接入库；关=只解析输出实体给下游（如「确认记账」）。
/// （struct 名沿用 RecognizeTodoIntent 以保持已导入快捷指令的绑定不失效。）
struct RecognizeTodoIntent: AppIntent {
    static let title: LocalizedStringResource = "屏幕识别"
    static let description = IntentDescription("对截图 OCR 出的文本做识别入库（快递、行程、待办、记账）。")
    static let openAppWhenRun = false

    @Parameter(title: "文本")
    var text: String

    @Parameter(title: "直接入库", description: "开：直接入库（默认）；关：只解析输出，交给后续「确认记账」等动作再入库。",
               default: true)
    var autoIngest: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[InboxItemEntity]> & ProvidesDialog {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .result(value: [], dialog: "截图里没有识别到文字")
        }

        if autoIngest {
            let context = OmnyApp.sharedModelContainer.mainContext
            // OCR 由快捷指令完成，故无原图；sourceImage 传 nil（后续走内置 OCR 时再带原图）
            // 走截图专用解析器：一屏多条多类一次抽取（快递/行程/待办/记账），忽略 OCR 噪声。
            // awaitEnrichment：Intent 返回后进程挂起，同步等记账分类补完，否则识屏记账永远无分类
            let items = await Ingestor.ingest(text: trimmed, source: .screenshot,
                                              parser: AppSettings.shared.screenParser,
                                              awaitEnrichment: true, context: context)
            guard !items.isEmpty else {
                return .result(value: [], dialog: "没有识别到内容")
            }
            let summary = items.map(\.intentSummary).joined(separator: "；")
            // 截图识别的待办标了待确认，提示去 App 勾选；其余类型直接入对应分类
            let suffix = items.contains { $0.needsReview } ? "，打开 Omny 确认" : ""
            return .result(value: [], dialog: IntentDialog(stringLiteral: "已识别：\(summary)\(suffix)"))
        }

        // 只解析不入库：输出实体给下游（截图入口不过滤类型）
        let entities = await ParseTextIntent.parseToEntities(trimmed, parser: AppSettings.shared.screenParser)
        guard !entities.isEmpty else {
            return .result(value: [], dialog: "没有识别到内容")
        }
        let summary = entities.map(\.intentSummary).joined(separator: "；")
        return .result(value: entities, dialog: IntentDialog(stringLiteral: "已识别 \(entities.count) 条：\(summary)"))
    }
}

extension InboxItem {
    var intentSummary: String {
        switch kind {
        case .package:
            let code = pickupCode.map { "，取件码 \($0)" } ?? ""
            return "\(carrier ?? "快递")\(code)"
        case .trip:
            if tripKindRaw == "hotel" { return "住宿 \(departPlace ?? "")" }
            return "行程 \(tripNumber ?? "")"
        case .todo: return "待办 \(todoTitle ?? "")"
        case .bookmark: return "收藏 \(bookmarkTitle ?? urlString ?? "")"
        case .expense:
            let amt = amount.map { "\($0)元" } ?? ""
            let label = expenseDirection == .income ? "收入" : "支出"
            return "\(label) \(amt)\(merchant.map { "（\($0)）" } ?? "")"
        case .unclassified: return "未分类（需确认）"
        }
    }
}

struct OmnyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ParseTextIntent(),
                    phrases: ["用 \(.applicationName) 解析文本"],
                    shortTitle: "解析文本", systemImageName: "text.viewfinder")
        AppShortcut(intent: RecognizeTodoIntent(),
                    phrases: ["用 \(.applicationName) 屏幕识别"],
                    shortTitle: "屏幕识别", systemImageName: "text.viewfinder")
        // 「确认记账」：接上游解析输出的条目，requestDisambiguation 循环弹窗核对记账（iOS 16+，不进 App）
        AppShortcut(intent: ConfirmExpenseIntent(),
                    phrases: ["用 \(.applicationName) 确认记账"],
                    shortTitle: "确认记账", systemImageName: "checklist")
    }
}
