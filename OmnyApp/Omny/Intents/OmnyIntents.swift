import AppIntents
import SwiftData
import SwiftUI

/// 快捷指令动作 ①：解析文本（短信自动化用）
/// 自动化：收到信息 → 运行本动作（输入 = 信息内容），无感入库。
struct ParseTextIntent: AppIntent {
    static let title: LocalizedStringResource = "解析文本"
    static let description = IntentDescription("把短信或任意文本交给 Omny 解析入库（快递、行程、待办）。")
    static let openAppWhenRun = false

    @Parameter(title: "文本")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = OmnyApp.sharedModelContainer.mainContext
        // 解析文本通道只过滤收藏；快递/行程/待办（含会议通知等）都入库
        let items = await Ingestor.ingest(text: text, source: .sms,
                                          allowedTypes: [.package, .trip, .todo], context: context)
        guard !items.isEmpty else {
            return .result(dialog: "没有识别到快递、行程或待办")
        }
        let summary = items.map(\.intentSummary).joined(separator: "；")
        return .result(dialog: IntentDialog(stringLiteral: "已入库：\(summary)"))
    }
}

/// 快捷指令动作 ②：屏幕识别（截屏 → 快捷指令内置 OCR → 文本传入）
/// iOS 快捷指令自带「识别图像文本」动作，OCR 在快捷指令侧完成，本动作直接收文本，
/// 走完整解析管线通用识别（快递/行程/待办/收藏四类都支持），按识别结果落到对应分类。
/// （struct 名沿用 RecognizeTodoIntent 以保持已导入快捷指令的绑定不失效。）
struct RecognizeTodoIntent: AppIntent {
    static let title: LocalizedStringResource = "屏幕识别"
    static let description = IntentDescription("对截图 OCR 出的文本做识别入库（快递、行程、待办、收藏）。")
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
        // 走截图专用解析器：一屏多条多类一次抽取（快递/行程/待办），忽略 OCR 噪声。
        let items = await Ingestor.ingest(text: trimmed, source: .screenshot,
                                          parser: AppSettings.shared.screenParser, context: context)
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
    }
}
