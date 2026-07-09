import AppIntents
import SwiftData
import SwiftUI

/// 快捷指令动作 ①：解析文本（短信自动化用）
/// 自动化：收到信息 → 运行本动作（输入 = 信息内容），无感入库。
struct ParseTextIntent: AppIntent {
    static let title: LocalizedStringResource = "解析文本"
    static let description = IntentDescription("把短信或任意文本交给 Omny 解析入库（快递、行程、待办、链接）。")
    static let openAppWhenRun = false

    @Parameter(title: "文本")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = OmnyApp.sharedModelContainer.mainContext
        let items = await Ingestor.ingest(text: text, source: .sms, context: context)
        let summary = items.map(\.intentSummary).joined(separator: "；")
        return .result(dialog: IntentDialog(stringLiteral: "已入库：\(summary)"))
    }
}

/// 快捷指令动作 ②：识别待办（截屏后调用，输入 = 截图）
/// Omny 内部完成 OCR + LLM 提取，识别出的待办标记"待确认"，打开 App 勾选入库。
struct RecognizeTodoIntent: AppIntent {
    static let title: LocalizedStringResource = "识别待办"
    static let description = IntentDescription("对截图做 OCR 并用 LLM 提取待办事项。")
    static let openAppWhenRun = false

    @Parameter(title: "截图")
    var image: IntentFile

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let data = image.data
        let text = try await OCRService.recognizeText(in: data)
        guard !text.isEmpty else {
            return .result(dialog: "截图里没有识别到文字")
        }
        let context = OmnyApp.sharedModelContainer.mainContext
        let items = await Ingestor.ingest(text: text, source: .screenshot,
                                          sourceImage: data, context: context)
        let todoCount = items.filter { $0.kind == .todo }.count
        if todoCount > 0 {
            return .result(dialog: IntentDialog(stringLiteral: "识别到 \(todoCount) 条待办，打开 Omny 确认"))
        }
        return .result(dialog: "没有识别到待办，原文已存入待处理")
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
                    phrases: ["用 \(.applicationName) 识别待办"],
                    shortTitle: "识别待办", systemImageName: "checklist")
    }
}
