import Foundation
import SwiftData
import OmnyCore

/// 入库服务：所有入口（短信快捷指令、截图 OCR、分享、手动）汇到这里。
/// 文本 → 解析管线 → InboxItem 落库；快递按单号/取件码合并、状态只前进。
@MainActor
enum Ingestor {

    @discardableResult
    static func ingest(text: String, source: ItemSource,
                       sourceImage: Data? = nil,
                       context: ModelContext) async -> [InboxItem] {
        let result: ParseResult?
        do {
            result = try await AppSettings.shared.parserPipeline.parse(text)
        } catch {
            result = nil
        }

        guard let result else {
            // 规则和 LLM 都没认出来 → 未分类，进"需处理"
            let item = InboxItem(kind: .unclassified, source: source, rawText: text)
            item.needsReview = true
            item.sourceImage = sourceImage
            context.insert(item)
            try? context.save()
            return [item]
        }

        let items: [InboxItem]
        switch result.payload {
        case .package(let info):
            items = [ingestPackage(info, text: text, source: source, context: context)]
        case .trip(let info):
            items = [ingestTrip(info, text: text, source: source, context: context)]
        case .todos(let todos):
            items = todos.map { todo in
                let item = InboxItem(kind: .todo, source: source, rawText: text)
                item.todoTitle = todo.title
                item.todoDue = resolveDate(todo.due)
                item.needsPush = true
                item.needsReview = source == .screenshot // 截图识别的待办先让用户确认
                item.sourceImage = sourceImage
                context.insert(item)
                return item
            }
        case .bookmark(let info):
            let item = InboxItem(kind: .bookmark, source: source, rawText: text)
            item.urlString = info.url.absoluteString
            item.bookmarkTitle = info.title
            context.insert(item)
            // 补标题和打标不阻塞入库（短信快捷指令等入口要求即时返回）
            Task { await enrichBookmark(item, context: context) }
            items = [item]
        }

        for item in items where result.confidence < 0.8 {
            item.needsReview = true
        }
        try? context.save()
        return items
    }

    // MARK: 收藏：分享/手动入口固定落成收藏，不走解析管线

    /// 分享面板与收藏页手动添加进来的内容，定位就是收藏：
    /// 带链接的抽出 URL + 标题，纯文本原样保存，随后交给 LLM 自动打标。
    @discardableResult
    static func ingestBookmark(text: String, urlString: String? = nil,
                               source: ItemSource, context: ModelContext) async -> InboxItem {
        var combined = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let urlString, !combined.contains(urlString) {
            combined = combined.isEmpty ? urlString : combined + "\n" + urlString
        }

        let item = InboxItem(kind: .bookmark, source: source, rawText: combined)
        if let info = RuleParser.extractBookmark(combined) {
            item.urlString = info.url.absoluteString
            item.bookmarkTitle = info.title
        } else {
            item.urlString = urlString
        }
        context.insert(item)
        try? context.save()
        await enrichBookmark(item, context: context)
        return item
    }

    /// 收藏的入库后处理：先补标题（分享面板常只给裸链接，X/微博等尤其），再 LLM 打标。
    /// 顺序有讲究：标题抓回来能明显提高打标准确率。
    static func enrichBookmark(_ item: InboxItem, context: ModelContext,
                               refetchTitle: Bool = false) async {
        if refetchTitle || (item.bookmarkTitle ?? "").isEmpty,
           let urlString = item.urlString, let url = URL(string: urlString),
           let title = await LinkTitleFetcher().fetchTitle(for: url) {
            item.bookmarkTitle = title
            try? context.save()
        }
        await autoTag(item, context: context)
    }

    /// LLM 自动打标：从设置页配置的 tag 列表里挑选。
    /// 失败时返回错误描述（nil = 请求成功，但模型可能认为都不贴切、保持无标签），
    /// 供「AI 重新打标」和设置页测试按钮展示，不再静默吞错。
    @discardableResult
    static func autoTag(_ item: InboxItem, context: ModelContext) async -> String? {
        guard let config = AppSettings.shared.llmConfig else {
            return "未配置 LLM：请在设置里填入 API Key"
        }
        let candidates = AppSettings.shared.bookmarkTags
        guard !candidates.isEmpty else { return "标签列表为空：请在设置 → 收藏标签里添加" }

        let content = [item.bookmarkTitle, item.rawText, item.urlString]
            .compactMap { $0 }
            .joined(separator: "\n")
        let classifier = LLMTagClassifier(config: config)
        do {
            let tags = try await classifier.classify(content, candidates: candidates)
            if !tags.isEmpty {
                item.tags = tags
                try? context.save()
            }
            return nil
        } catch {
            return describeLLMError(error)
        }
    }

    /// 把 LLM 层的错误翻译成用户能定位问题的文案
    static func describeLLMError(_ error: Error) -> String {
        switch error {
        case LLMParseError.httpError(let status, let body):
            let detail = String(body.prefix(200))
            return "HTTP \(status)\(detail.isEmpty ? "" : "：\(detail)")"
        case LLMParseError.malformedResponse:
            return "响应格式无法解析：端点可能与所选协议不匹配（Claude / OpenAI 兼容）"
        case let urlError as URLError:
            return "网络错误：\(urlError.localizedDescription)"
        default:
            return error.localizedDescription
        }
    }

    // MARK: 快递合并：同一包裹多条短信，状态只前进不回退

    private static func ingestPackage(_ info: PackageInfo, text: String,
                                      source: ItemSource, context: ModelContext) -> InboxItem {
        if let existing = findExistingPackage(info, context: context) {
            existing.carrier = info.carrier ?? existing.carrier
            existing.trackingNumber = info.trackingNumber ?? existing.trackingNumber
            existing.trackingTail = info.trackingTail ?? existing.trackingTail
            existing.pickupCode = info.pickupCode ?? existing.pickupCode
            existing.station = info.station ?? existing.station
            existing.packageStatus = max(existing.packageStatus, info.status)
            existing.rawText = text
            existing.createdAt = .now
            return existing
        }
        let item = InboxItem(kind: .package, source: source, rawText: text)
        item.carrier = info.carrier
        item.trackingNumber = info.trackingNumber
        item.trackingTail = info.trackingTail
        item.pickupCode = info.pickupCode
        item.station = info.station
        item.packageStatus = info.status
        context.insert(item)
        return item
    }

    private static func findExistingPackage(_ info: PackageInfo, context: ModelContext) -> InboxItem? {
        let kindRaw = ItemKind.package.rawValue
        let descriptor = FetchDescriptor<InboxItem>(predicate: #Predicate { $0.kindRaw == kindRaw })
        guard let packages = try? context.fetch(descriptor) else { return nil }
        if let number = info.trackingNumber,
           let hit = packages.first(where: { $0.trackingNumber == number }) {
            return hit
        }
        if let tail = info.trackingTail,
           let hit = packages.first(where: { $0.trackingTail == tail || $0.trackingNumber?.hasSuffix(tail) == true }) {
            return hit
        }
        return nil
    }

    private static func ingestTrip(_ info: TripInfo, text: String,
                                   source: ItemSource, context: ModelContext) -> InboxItem {
        let item = InboxItem(kind: .trip, source: source, rawText: text)
        item.tripKindRaw = info.kind.rawValue
        item.tripNumber = info.number
        item.departAt = resolveDate(info.departure)
        item.departPlace = info.departurePlace
        item.arriveAt = resolveDate(info.arrival)
        item.arrivePlace = info.arrivalPlace
        item.seat = info.seat
        context.insert(item)
        return item
    }

    /// 短信里的日期通常没有年份：补当前年；若已过去 180 天以上视为明年（跨年买票场景）
    static func resolveDate(_ components: DateComponents?) -> Date? {
        guard var c = components else { return nil }
        let calendar = Calendar.current
        if c.year == nil { c.year = calendar.component(.year, from: .now) }
        guard let date = calendar.date(from: c) else { return nil }
        if date.timeIntervalSinceNow < -180 * 24 * 3600,
           let nextYear = calendar.date(byAdding: .year, value: 1, to: date) {
            return nextYear
        }
        return date
    }
}
