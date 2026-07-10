import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import OmnyCore

/// 把一段 JSON 包成 Claude Messages 响应（自由函数，避免 @Sendable 闭包捕获 self）
private func claudeEnvelope(_ inner: String) -> Data {
    try! JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": inner]]])
}

/// Issue 1 验证：解析文本通道（ParseTextIntent）过滤掉收藏，快递/行程/待办入库。
///
/// 过滤逻辑本体在 App 层 Ingestor.ingest（依赖 SwiftData，无法在 SwiftPM 测试里跑），
/// 这里把 Ingestor 的过滤判断原样复刻为一个纯函数，喂真实解析结果验证其行为等价。
/// 复刻的两条规则（对应 Ingestor.swift）：
///   1. 有结果但类型不在白名单 → 丢弃
///   2. 无结果(nil) 且开了白名单 → 丢弃（不产出未分类项）
final class IngestFilterTests: XCTestCase {

    /// 与 Ingestor.ingest 中的过滤等价：给定解析结果和白名单，返回是否入库。
    /// allowedTypes == nil 表示全放行（截图/分享/手动入口）。
    private func passesFilter(_ result: ParseResult?, allowedTypes: Set<ItemType>?) -> Bool {
        guard let allowedTypes else {
            // 全放行：nil 结果也会入库（未分类项），非 nil 一律入库
            return true
        }
        guard let result else {
            // 白名单模式 + 没认出 → 不入库
            return false
        }
        return allowedTypes.contains(result.payload.itemType)
    }

    /// 解析文本通道用的白名单：只过滤收藏，快递/行程/待办都入库
    private let textChannelWhitelist: Set<ItemType> = [.package, .trip, .todo]

    // MARK: - 组装「结构化主 + 待办兜底」管线（同 App 的 parserPipeline 配了 LLM 的形态）

    private func makePipeline(
        structured: @escaping @Sendable (URLRequest) -> (Data, Int),
        todo: @escaping @Sendable (URLRequest) -> (Data, Int)
    ) -> ParserPipeline {
        ParserPipeline(
            primary: LLMStructuredParser(config: .claude(apiKey: "sk-test"),
                                         transport: MockTransport(handler: structured)),
            fallback: LLMTodoParser(config: .claude(apiKey: "sk-test"),
                                    transport: MockTransport(handler: todo)))
    }

    // MARK: - 快递短信 → package → 通过

    func testPackageSMSPasses() async throws {
        let pkg = #"{"carrier":"顺丰速运","trackingNumber":null,"trackingTail":"6707","pickupCode":"3-2-2011","station":"河畔小区菜鸟驿站"}"#
        let pipeline = makePipeline(
            structured: { _ in (claudeEnvelope(pkg), 200) },
            todo: { _ in (Data(), 200) })
        let result = try await pipeline.parse("【顺丰速运】您的快递已到河畔小区菜鸟驿站，凭取件码3-2-2011取件，运单尾号6707")

        XCTAssertEqual(result?.payload.itemType, .package)
        XCTAssertTrue(passesFilter(result, allowedTypes: textChannelWhitelist),
                      "快递短信应通过解析文本通道过滤")
    }

    // MARK: - 行程短信 → trip → 通过

    func testTripSMSPasses() async throws {
        let trip = #"{"kind":"train","number":"G101","departure":"2026-07-10T08:30:00+08:00","departurePlace":"北京南","arrival":null,"arrivalPlace":null,"seat":"7车12A号"}"#
        let pipeline = makePipeline(
            structured: { _ in (claudeEnvelope(trip), 200) },
            todo: { _ in (Data(), 200) })
        let result = try await pipeline.parse("您购买的G101次列车，北京南08:30开，7车12A号")

        XCTAssertEqual(result?.payload.itemType, .trip)
        XCTAssertTrue(passesFilter(result, allowedTypes: textChannelWhitelist),
                      "行程短信应通过解析文本通道过滤")
    }

    // MARK: - 待办文本 → todos → 通过（Issue 1 调整：待办纳入白名单）

    func testTodoTextPasses() async throws {
        // 结构化主解析器对自由文本返回 nil（无快递/行程/URL 关键词），落到待办兜底
        let todoInner = #"{"todos":[{"title":"把周报发给老板","due":null},{"title":"预约体检","due":null}]}"#
        let pipeline = makePipeline(
            structured: { _ in (Data(), 200) },
            todo: { _ in (claudeEnvelope(todoInner), 200) })
        let result = try await pipeline.parse("明天下午三点前把周报发给老板，记得预约体检")

        XCTAssertEqual(result?.payload.itemType, .todo, "自由文本应被识别成待办")
        XCTAssertTrue(passesFilter(result, allowedTypes: textChannelWhitelist),
                      "待办应通过解析文本通道过滤（含会议通知等，Issue 1 调整后待办保留）")
    }

    // MARK: - 会议通知短信 → todos → 通过

    func testMeetingSMSPassesAsTodo() async throws {
        let todoInner = #"{"todos":[{"title":"参加周三下午2点项目评审会","due":"2026-07-15T14:00:00+08:00"}]}"#
        let pipeline = makePipeline(
            structured: { _ in (Data(), 200) },
            todo: { _ in (claudeEnvelope(todoInner), 200) })
        let result = try await pipeline.parse("【会议通知】周三下午2点在3楼会议室召开项目评审会，请准时参加")

        XCTAssertEqual(result?.payload.itemType, .todo)
        XCTAssertTrue(passesFilter(result, allowedTypes: textChannelWhitelist),
                      "会议通知短信应作为待办入库")
    }

    // MARK: - 收藏链接 → bookmark → 被过滤

    func testBookmarkFilteredOut() async throws {
        let pipeline = makePipeline(
            structured: { _ in (Data(), 200) },  // bookmark 走正则，不会真的用到
            todo: { _ in (Data(), 200) })
        let result = try await pipeline.parse("分享一篇好文章 https://example.com/article")

        XCTAssertEqual(result?.payload.itemType, .bookmark)
        XCTAssertFalse(passesFilter(result, allowedTypes: textChannelWhitelist),
                       "收藏不应通过解析文本通道过滤（Issue 1：短信解析不要收藏）")
    }

    // MARK: - 完全没认出 → nil → 白名单模式下被过滤（不产出未分类项）

    func testUnclassifiedFilteredOutUnderWhitelist() async throws {
        // 结构化 nil + 待办兜底也 nil（空 todos）→ 管线返回 nil
        let emptyTodos = #"{"todos":[]}"#
        let pipeline = makePipeline(
            structured: { _ in (Data(), 200) },
            todo: { _ in (claudeEnvelope(emptyTodos), 200) })
        let result = try await pipeline.parse("随便一句没有任何结构的闲聊内容")

        XCTAssertNil(result, "无法识别应返回 nil")
        XCTAssertFalse(passesFilter(result, allowedTypes: textChannelWhitelist),
                       "白名单模式下 nil 结果不应入库（不产出未分类项）")
    }

    // MARK: - 对照：全放行入口（截图/分享/手动）不受白名单影响

    func testNilWhitelistLetsTodoThrough() async throws {
        let todoInner = #"{"todos":[{"title":"买牛奶","due":null}]}"#
        let pipeline = makePipeline(
            structured: { _ in (Data(), 200) },
            todo: { _ in (claudeEnvelope(todoInner), 200) })
        let result = try await pipeline.parse("记得买牛奶")

        XCTAssertEqual(result?.payload.itemType, .todo)
        XCTAssertTrue(passesFilter(result, allowedTypes: nil),
                      "全放行入口（如屏幕识别/截图）应放行待办")
    }

    func testNilWhitelistKeepsUnclassified() async throws {
        // 全放行 + 无结果 → Ingestor 会产出未分类项，故 passesFilter 应为 true
        let emptyTodos = #"{"todos":[]}"#
        let pipeline = makePipeline(
            structured: { _ in (Data(), 200) },
            todo: { _ in (claudeEnvelope(emptyTodos), 200) })
        let result = try await pipeline.parse("无结构闲聊")

        XCTAssertNil(result)
        XCTAssertTrue(passesFilter(result, allowedTypes: nil),
                      "全放行入口 nil 结果仍入库为未分类项")
    }
}
