import AppIntents
import SwiftData
import SwiftUI

/// 快捷指令动作 ①：解析文本（短信自动化用）
/// 自动化：收到信息 → 运行本动作（输入 = 信息内容），无感入库。
struct ParseTextIntent: AppIntent {
    static let title: LocalizedStringResource = "解析文本"
    static let description = IntentDescription("把短信或任意文本交给 Omny 解析入库（快递、行程、待办、记账）。")
    static let openAppWhenRun = false

    @Parameter(title: "文本")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = OmnyApp.sharedModelContainer.mainContext
        // 解析文本通道只过滤收藏；快递/行程/待办/记账（含会议通知、动账短信等）都入库
        // awaitEnrichment：App Intent perform 返回后进程会挂起，必须同步等记账分类/收藏打标补完
        let items = await Ingestor.ingest(text: text, source: .sms,
                                          allowedTypes: [.package, .trip, .todo, .expense],
                                          awaitEnrichment: true, context: context)
        guard !items.isEmpty else {
            return .result(dialog: "没有识别到快递、行程、待办或记账")
        }
        let summary = items.map(\.intentSummary).joined(separator: "；")
        return .result(dialog: IntentDialog(stringLiteral: "已入库：\(summary)"))
    }
}

/// 快捷指令动作 ②：屏幕识别（截屏 → 快捷指令内置 OCR → 文本传入）
/// iOS 快捷指令自带「识别图像文本」动作，OCR 在快捷指令侧完成，本动作直接收文本，
/// 走截图专用解析器 ScreenParser（一屏多条多类：快递/行程/待办/记账），按识别结果落到对应分类。
/// 收藏不作为截图识别目标（截图里的链接少见且噪声多，收藏走分享面板入口）。
/// （struct 名沿用 RecognizeTodoIntent 以保持已导入快捷指令的绑定不失效。）
struct RecognizeTodoIntent: AppIntent {
    static let title: LocalizedStringResource = "屏幕识别"
    static let description = IntentDescription("对截图 OCR 出的文本做识别入库（快递、行程、待办、记账）。")
    static let openAppWhenRun = false

    @Parameter(title: "文本")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .result(dialog: "截图里没有识别到文字")
        }
        let context = OmnyApp.sharedModelContainer.mainContext
        // OCR 由快捷指令完成，故无原图；sourceImage 传 nil（后续走内置 OCR 时再带原图）
        // 走截图专用解析器：一屏多条多类一次抽取（快递/行程/待办/记账），忽略 OCR 噪声。
        // awaitEnrichment：Intent 返回后进程挂起，同步等记账分类补完，否则识屏记账永远无分类
        let items = await Ingestor.ingest(text: trimmed, source: .screenshot,
                                          parser: AppSettings.shared.screenParser,
                                          awaitEnrichment: true, context: context)
        guard !items.isEmpty else {
            return .result(dialog: "没有识别到内容")
        }
        let summary = items.map(\.intentSummary).joined(separator: "；")
        // 截图识别的待办标了待确认，提示去 App 勾选；其余类型直接入对应分类
        let suffix = items.contains { $0.needsReview } ? "，打开 Omny 确认" : ""
        return .result(dialog: IntentDialog(stringLiteral: "已识别：\(summary)\(suffix)"))
    }
}

extension InboxItem {
    var intentSummary: String {
        switch kind {
        case .package:
            let code = pickupCode.map { "，取件码 \($0)" } ?? ""
            return "\(carrier ?? "快递")\(code)"
        case .trip: return "行程 \(tripNumber ?? "")"
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
        // 「确认记账」用 interactive snippet（SnippetIntent，iOS 26+）；低版本不注册
        if #available(iOS 26, *) {
            AppShortcut(intent: ConfirmExpenseIntent(),
                        phrases: ["用 \(.applicationName) 确认记账"],
                        shortTitle: "确认记账", systemImageName: "checklist")
        }
    }
}
