import Foundation
import SwiftData
import OmnyCore

/// 入库服务：所有入口（短信快捷指令、截图 OCR、分享、手动）汇到这里。
/// 文本 → 解析管线 → InboxItem 落库；快递按单号/取件码合并、状态只前进。
@MainActor
enum Ingestor {

    /// 入库。`allowedTypes` 为类型白名单：解析出的类型不在其中则丢弃（不落库）。
    /// nil 表示全放行（截图/分享/手动等入口用）；「解析文本」快捷指令传 [.package, .trip, .todo]，
    /// 短信里混进的收藏（链接）不入库。
    /// 入库。`allowedTypes` 为类型白名单：解析出的类型不在其中则丢弃（不落库）。
    /// nil 表示全放行（截图/分享/手动等入口用）；「解析文本」快捷指令传 [.package, .trip, .todo]，
    /// 短信里混进的收藏（链接）不入库。
    /// `parser` 为空时用默认 parserPipeline（短信/分享等，整段归一类）；
    /// 截图入口传 screenParser（一屏多条多类，返回 .mixed）。
    @discardableResult
    static func ingest(text: String, source: ItemSource,
                       sourceImage: Data? = nil,
                       allowedTypes: Set<ItemType>? = nil,
                       parser: (any Parser)? = nil,
                       awaitEnrichment: Bool = false,
                       context: ModelContext) async -> [InboxItem] {
        let result: ParseResult?
        do {
            let p = parser ?? AppSettings.shared.parserPipeline
            result = try await p.parse(text)
        } catch {
            result = nil
        }

        guard let result else {
            // 带白名单的入口（解析文本）没认出目标类型时不留未分类项，直接丢弃
            if allowedTypes != nil { return [] }
            // 规则和 LLM 都没认出来 → 未分类，进"需处理"（截图脏文本降级失败时也走这里，原文不丢）
            let item = InboxItem(kind: .unclassified, source: source, rawText: text)
            item.needsReview = true
            item.sourceImage = sourceImage
            context.insert(item)
            // save 失败要如实反映：回滚插入并返回空，避免上层误报"已存入待处理"却查无此条
            guard saveOrRollback([item], context: context) else { return [] }
            return [item]
        }

        // 展平多条多类（mixed）为逐条单类载荷；非 mixed 就是单元素
        var payloads = result.payload.flattened
        // 类型白名单过滤：只保留白名单内的类型（截图入口 allowedTypes=nil 不过滤）
        if let allowedTypes {
            payloads = payloads.filter { allowedTypes.contains($0.itemType) }
        }
        guard !payloads.isEmpty else { return [] }

        return await ingestParsed(payloads, text: text, source: source,
                                  sourceImage: sourceImage,
                                  lowConfidence: result.confidence < AppSettings.shared.lowConfidenceThreshold,
                                  awaitEnrichment: awaitEnrichment, context: context)
    }

    /// 直接入库已解析好的载荷（跳过解析步骤），复用去重/合并/enrich。
    /// 供快捷指令「确认记账」等场景：上游已解析成 `InboxItemEntity` 带过来，
    /// 确认后还原成 payload 走这里入库——快递按单号合并、记账去重逻辑与自动入库完全一致。
    /// `lowConfidence` 为 true 时把本批标 needsReview（自动解析低置信场景；已确认的传 false）。
    @discardableResult
    static func ingestParsed(_ payloads: [ParsedPayload], text: String, source: ItemSource,
                             sourceImage: Data? = nil,
                             lowConfidence: Bool = false,
                             awaitEnrichment: Bool = false,
                             context: ModelContext) async -> [InboxItem] {
        guard !payloads.isEmpty else { return [] }
        var items: [InboxItem] = []
        for payload in payloads {
            items.append(contentsOf: ingestPayload(payload, text: text, source: source,
                                                    sourceImage: sourceImage, context: context))
        }

        if lowConfidence {
            for item in items { item.needsReview = true }
        }
        // save 失败要如实反映：回滚本次插入并返回空，避免上层误报"已入库"却查无此条
        guard saveOrRollback(items, context: context) else { return [] }

        // 入库后处理（收藏补标题+打标、记账补分类）：默认游离 Task 不阻塞前台 UI；
        // 快捷指令入口（App Intent）传 awaitEnrichment=true——Intent perform 返回后进程会被系统
        // 挂起，游离 Task 来不及跑完，必须在返回前同步 await，否则记账分类/收藏标签永远补不上。
        await enrich(items, context: context, awaitEnrichment: awaitEnrichment)
        return items
    }

    /// 对入库条目做异步补全（收藏→补标题+打标；记账→补两级分类）。
    /// awaitEnrichment=true 时同步等待全部完成（快捷指令入口）；否则每条起游离 Task（前台入口）。
    private static func enrich(_ items: [InboxItem], context: ModelContext,
                               awaitEnrichment: Bool) async {
        for item in items {
            let work: () async -> Void
            switch item.kind {
            case .bookmark:
                work = { await enrichBookmark(item, context: context) }
            case .expense:
                // 已有分类的（去重命中的存量条目）跳过，避免重复调 LLM
                guard item.categoryMajor == nil else { continue }
                work = { await categorizeExpense(item, context: context) }
            default:
                continue
            }
            if awaitEnrichment {
                await work()
            } else {
                Task { await work() }
            }
        }
    }

    /// 单条载荷 → InboxItem（快递按单号合并；一条 .todos 可能展开成多条）。
    private static func ingestPayload(_ payload: ParsedPayload, text: String, source: ItemSource,
                                      sourceImage: Data?, context: ModelContext) -> [InboxItem] {
        switch payload {
        case .package(let info):
            return [ingestPackage(info, text: text, source: source, context: context)]
        case .trip(let info):
            return [ingestTrip(info, text: text, source: source, context: context)]
        case .todos(let todos):
            return todos.map { todo in
                let item = InboxItem(kind: .todo, source: source, rawText: text)
                item.todoTitle = todo.title
                item.todoDue = resolveDate(todo.due)
                item.needsPush = true
                // 截图识别的待办先让用户确认（高级设置里可改成直接入库）
                item.needsReview = source == .screenshot
                    && !AppSettings.shared.screenshotTodoDirectIngest
                item.sourceImage = sourceImage
                context.insert(item)
                return item
            }
        case .bookmark(let info):
            let item = InboxItem(kind: .bookmark, source: source, rawText: text)
            item.urlString = info.url.absoluteString
            item.bookmarkTitle = info.title
            context.insert(item)
            // 补标题+打标由 ingest 统一 enrich（前台游离 / 快捷指令同步 await），此处不再起游离 Task
            return [item]
        case .expense(let info):
            return [ingestExpense(info, text: text, source: source, context: context)]
        case .mixed(let inner):
            // 理论上已被 flattened 展开，防御性再展一层
            return inner.flatMap { ingestPayload($0, text: text, source: source,
                                                 sourceImage: sourceImage, context: context) }
        }
    }

    /// 保存，失败时回滚本次未提交的更改。返回是否保存成功。
    /// 用 context.rollback() 撤销所有未保存的 insert/update（本次入库尚未 save，回滚即清空这批新条目），
    /// 避免把"半落库"状态留给用户——上层据返回值如实提示，不再出现"提示已存入却查无此条"。
    private static func saveOrRollback(_ items: [InboxItem], context: ModelContext) -> Bool {
        do {
            try context.save()
            return true
        } catch {
            context.rollback()
            return false
        }
    }

    // MARK: 收藏：分享/手动入口固定落成收藏，不走解析管线

    /// 分享面板与收藏页手动添加进来的内容，定位就是收藏：
    /// 带链接的抽出 URL + 标题，纯文本原样保存，随后交给 LLM 自动打标。
    @discardableResult
    /// manualTags 非空时用用户手选的标签，跳过 LLM 自动打标（尊重手动选择）；
    /// 为 nil 时走原自动打标流程。
    static func ingestBookmark(text: String, urlString: String? = nil,
                               sourceImage: Data? = nil,
                               manualTags: [String]? = nil,
                               source: ItemSource, context: ModelContext) async -> InboxItem {
        var combined = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let urlString, !combined.contains(urlString) {
            combined = combined.isEmpty ? urlString : combined + "\n" + urlString
        }

        let item = InboxItem(kind: .bookmark, source: source, rawText: combined)
        item.sourceImage = sourceImage
        if let info = RuleParser.extractBookmark(combined) {
            item.urlString = info.url.absoluteString
            item.bookmarkTitle = info.title
        } else {
            item.urlString = urlString
        }
        if let manualTags, !manualTags.isEmpty { item.tags = manualTags }
        context.insert(item)
        try? context.save()
        await enrichBookmark(item, context: context, runAutoTag: manualTags?.isEmpty ?? true)
        return item
    }

    /// 收藏的入库后处理：先补标题（分享面板常只给裸链接，X/微博等尤其），再 LLM 打标。
    /// 顺序有讲究：标题抓回来能明显提高打标准确率。
    static func enrichBookmark(_ item: InboxItem, context: ModelContext,
                               refetchTitle: Bool = false, runAutoTag: Bool = true) async {
        if refetchTitle || (item.bookmarkTitle ?? "").isEmpty,
           let urlString = item.urlString, let url = URL(string: urlString),
           let title = await LinkTitleFetcher().fetchTitle(for: url) {
            item.bookmarkTitle = title
            try? context.save()
        }
        if runAutoTag { await autoTag(item, context: context) }
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

    // MARK: 记账入库：CSV 用 txnID 精确去重；短信/截图用金额+时间窗+尾号/商户模糊去重

    private static func ingestExpense(_ info: ExpenseInfo, text: String,
                                      source: ItemSource, context: ModelContext) -> InboxItem {
        let occurredAt = resolveDate(info.occurredAt)
        if let existing = findExistingExpense(info, occurredAt: occurredAt, context: context) {
            // 已存在（多渠道重复）：补齐更完整的字段，不新增
            existing.amount = existing.amount ?? info.amount
            existing.merchant = existing.merchant ?? info.merchant
            existing.channel = existing.channel ?? info.channel
            existing.cardTail = existing.cardTail ?? info.cardTail
            existing.txnID = existing.txnID ?? info.txnID
            if existing.occurredAt == nil { existing.occurredAt = occurredAt }
            return existing
        }
        let item = InboxItem(kind: .expense, source: source, rawText: text)
        item.expenseDirection = info.direction
        item.amount = info.amount
        item.merchant = info.merchant
        item.categoryMajor = info.categoryMajor
        item.categorySub = info.categorySub
        item.occurredAt = occurredAt
        item.channel = info.channel
        item.cardTail = info.cardTail
        item.txnID = info.txnID
        context.insert(item)
        // 两级分类由 ingest 统一 enrich（前台游离 / 快捷指令同步 await），此处不再起游离 Task
        return item
    }

    /// 手动记账：用户在表单里填好的结构化字段直接入库，不走解析管线。
    /// 与自动记账的区别是「尊重用户输入」——不做模糊去重（手动录入即用户明确意图），
    /// 也不异步调 LLM 覆盖分类（用户填了什么就是什么；没填分类则留空，不自动补）。
    /// `item` 非空时为编辑已有条目（表单回写），空则新建。返回落库后的条目，save 失败返回 nil。
    @discardableResult
    static func addManualExpense(_ info: ExpenseInfo, occurredAt: Date?,
                                 editing item: InboxItem? = nil,
                                 context: ModelContext) -> InboxItem? {
        let target: InboxItem
        if let item {
            target = item
        } else {
            target = InboxItem(kind: .expense, source: .manual, rawText: "")
            context.insert(target)
        }
        target.expenseDirection = info.direction
        target.amount = info.amount
        target.merchant = info.merchant
        target.categoryMajor = info.categoryMajor
        target.categorySub = info.categorySub
        target.occurredAt = occurredAt
        target.channel = info.channel
        target.cardTail = info.cardTail
        target.txnID = info.txnID
        // 手动录入字段完整、意图明确，不进「需处理」
        target.needsReview = false
        guard saveOrRollback([target], context: context) else { return nil }
        return target
    }

    /// 记账去重：优先 txnID 精确匹配（CSV 权威源）；无 txnID 时用
    /// 「金额相等 + 交易时间 ±时间窗（默认 10 分钟，高级设置可调）+ 卡尾号或商户其一匹配」
    /// 判为同一笔（短信/截图重复）。
    private static func findExistingExpense(_ info: ExpenseInfo, occurredAt: Date?,
                                            context: ModelContext) -> InboxItem? {
        let kindRaw = ItemKind.expense.rawValue
        let descriptor = FetchDescriptor<InboxItem>(predicate: #Predicate { $0.kindRaw == kindRaw })
        guard let expenses = try? context.fetch(descriptor) else { return nil }

        if let txnID = info.txnID,
           let hit = expenses.first(where: { $0.txnID == txnID }) {
            return hit
        }
        guard let amount = info.amount else { return nil }
        return expenses.first { e in
            guard e.amount == amount else { return false }
            // 时间窗：两边都有时间才比，任一缺失则不靠时间判定
            if let a = occurredAt, let b = e.occurredAt,
               abs(a.timeIntervalSince(b))
                   > Double(AppSettings.shared.expenseDedupWindowMinutes) * 60 { return false }
            let tailMatch = info.cardTail != nil && e.cardTail == info.cardTail
            let merchantMatch = info.merchant != nil && e.merchant == info.merchant
            return tailMatch || merchantMatch
        }
    }

    /// LLM 补两级消费分类：从设置页配置的分类池里挑一个合法「大类/细分」。异步、不阻塞入库。
    @discardableResult
    static func categorizeExpense(_ item: InboxItem, context: ModelContext) async -> String? {
        guard let config = AppSettings.shared.llmConfig else {
            return "未配置 LLM：请在设置里填入 API Key"
        }
        let pool = AppSettings.shared.expenseCategoryPool
        guard !pool.isEmpty else { return "分类池为空：请在设置 → 消费分类里添加" }

        let content = [item.merchant, item.amount.map { "\($0)元" }, item.rawText]
            .compactMap { $0 }
            .joined(separator: "\n")
        let categorizer = LLMExpenseCategorizer(config: config)
        do {
            if let picked = try await categorizer.classify(content, pool: pool) {
                item.categoryMajor = picked.major
                item.categorySub = picked.sub
                try? context.save()
            }
            return nil
        } catch {
            return describeLLMError(error)
        }
    }

    private static func ingestTrip(_ info: TripInfo, text: String,
                                   source: ItemSource, context: ModelContext) -> InboxItem {
        let item = InboxItem(kind: .trip, source: source, rawText: text)
        item.tripKindRaw = info.kind.rawValue
        // 酒店无班次号（TripInfo.number 约定为空串），存 nil 让 UI 的 ?? 兜底生效
        item.tripNumber = info.number.isEmpty ? nil : info.number
        item.departAt = resolveDate(info.departure)
        item.departPlace = info.departurePlace
        item.arriveAt = resolveDate(info.arrival)
        item.arrivePlace = info.arrivalPlace
        item.seat = info.seat
        item.ticketGate = info.ticketGate
        item.seatClass = info.seatClass
        item.tripAddress = info.address
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
