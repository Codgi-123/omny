import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import OmnyCore

/// 把一段 JSON 文本包成 Claude Messages 响应（自由函数，避免 @Sendable 闭包捕获 self）
private func claudeEnvelope(_ inner: String) -> Data {
    try! JSONSerialization.data(withJSONObject: [
        "content": [["type": "text", "text": inner]],
    ])
}

private func structuredParser(
    _ handler: @escaping @Sendable (URLRequest) -> (Data, Int)
) -> LLMStructuredParser {
    LLMStructuredParser(config: .claude(apiKey: "sk-test"),
                        transport: MockTransport(handler: handler))
}

/// LLMStructuredParser：分类靠正则、结构化靠 LLM。
/// 复用 DidaSyncTests.swift 里定义的 MockTransport（同 target），喂预置 LLM 响应。
final class LLMStructuredParserTests: XCTestCase {

    // MARK: - 快递

    func testPackageExtractsFieldsAndStatusFromRules() async throws {
        // LLM 只给字段，不给状态；状态由本地正则从原文推断
        let inner = #"""
        {"carrier":"顺丰速运","trackingNumber":null,"trackingTail":"6707",
         "pickupCode":"3-2-2011","station":"河畔小区菜鸟驿站"}
        """#
        let p = structuredParser { _ in (claudeEnvelope(inner), 200) }
        let text = "【顺丰速运】您的快递已到河畔小区菜鸟驿站，凭取件码3-2-2011取件，运单尾号6707"
        let result = try await p.parse(text)

        guard case .package(let info) = try XCTUnwrap(result).payload else { return XCTFail() }
        XCTAssertEqual(info.carrier, "顺丰速运")
        XCTAssertNil(info.trackingNumber)
        XCTAssertEqual(info.trackingTail, "6707")
        XCTAssertEqual(info.pickupCode, "3-2-2011")
        XCTAssertEqual(info.station, "河畔小区菜鸟驿站")
        // 有取件码/到站 → 待取，来自 RuleParser.detectStatus
        XCTAssertEqual(info.status, .awaitingPickup)
        XCTAssertEqual(try XCTUnwrap(result).confidence, 0.9)
    }

    func testPackageStatusPickedUpFromRules() async throws {
        let inner = #"{"carrier":"中通快递","trackingNumber":null,"trackingTail":null,"pickupCode":null,"station":null}"#
        let p = structuredParser { _ in (claudeEnvelope(inner), 200) }
        let result = try await p.parse("【中通快递】您的包裹已签收，感谢使用")
        guard case .package(let info) = try XCTUnwrap(result).payload else { return XCTFail() }
        XCTAssertEqual(info.status, .pickedUp)
    }

    func testPackageUsesPackageSchemaAndPrompt() async throws {
        let inner = #"{"carrier":null,"trackingNumber":null,"trackingTail":null,"pickupCode":null,"station":null}"#
        let transport = MockTransport { _ in (claudeEnvelope(inner), 200) }
        let p = LLMStructuredParser(config: .claude(apiKey: "sk-test"), transport: transport)
        _ = try await p.parse("您有一个快递包裹待取")

        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        // 用的是快递提示词，且带上了 package 的 schema
        XCTAssertEqual((body?["system"] as? String)?.contains("快递"), true)
        let schema = ((body?["output_config"] as? [String: Any])?["format"] as? [String: Any])?["schema"] as? [String: Any]
        let props = schema?["properties"] as? [String: Any]
        XCTAssertNotNil(props?["trackingTail"])
        XCTAssertNotNil(props?["pickupCode"])
    }

    // MARK: - 行程

    func testTripExtractsTrainWithDateComponents() async throws {
        let inner = #"""
        {"kind":"train","number":"G101","departure":"2026-07-10T08:30:00+08:00",
         "departurePlace":"北京南","arrival":"2026-07-10T13:00:00+08:00",
         "arrivalPlace":"上海虹桥","seat":"7车12A号"}
        """#
        let p = structuredParser { _ in (claudeEnvelope(inner), 200) }
        let result = try await p.parse("您购买的G101次列车，北京南08:30开，7车12A号")

        guard case .trip(let info) = try XCTUnwrap(result).payload else { return XCTFail() }
        XCTAssertEqual(info.kind, .train)
        XCTAssertEqual(info.number, "G101")
        XCTAssertEqual(info.departure?.month, 7)
        XCTAssertEqual(info.departure?.day, 10)
        XCTAssertEqual(info.departure?.hour, 8)
        XCTAssertEqual(info.departure?.minute, 30)
        XCTAssertEqual(info.departurePlace, "北京南")
        XCTAssertEqual(info.arrivalPlace, "上海虹桥")
        XCTAssertEqual(info.seat, "7车12A号")
        XCTAssertEqual(try XCTUnwrap(result).confidence, 0.9)
    }

    func testTripExtractsFlight() async throws {
        let inner = #"""
        {"kind":"flight","number":"CA1831","departure":null,
         "departurePlace":"首都机场T3","arrival":null,"arrivalPlace":null,"seat":null}
        """#
        let p = structuredParser { _ in (claudeEnvelope(inner), 200) }
        let result = try await p.parse("您预订的CA1831航班，首都机场T3登机，请提前检票")

        guard case .trip(let info) = try XCTUnwrap(result).payload else { return XCTFail() }
        XCTAssertEqual(info.kind, .flight)
        XCTAssertEqual(info.number, "CA1831")
        XCTAssertEqual(info.departurePlace, "首都机场T3")
        XCTAssertNil(info.departure)
        XCTAssertNil(info.seat)
    }

    /// 短信常不写年份、LLM 也可能不带时区输出。旧的 ISO8601DateFormatter 对
    /// 缺年份(07-10T...)或缺时区(...T08:30:00)一律返回 nil，会丢失行程时间。
    /// 宽容解析后：缺年份→year 为 nil（下游补年）、缺时区→按字面时分抽取。
    func testTripHandlesMissingYearAndTimezone() async throws {
        let inner = #"""
        {"kind":"train","number":"D3082","departure":"07-10T08:30:00",
         "departurePlace":"杭州东","arrival":"2026-07-10T13:00:00",
         "arrivalPlace":"上海","seat":"2车15F号"}
        """#
        let p = structuredParser { _ in (claudeEnvelope(inner), 200) }
        let result = try await p.parse("您购买的D3082次列车，杭州东08:30开")

        guard case .trip(let info) = try XCTUnwrap(result).payload else { return XCTFail() }
        // 出发：缺年份，month/day/hour/minute 仍应抽出，year 为 nil
        XCTAssertNil(info.departure?.year, "缺年份时 year 应为 nil，交给下游补年")
        XCTAssertEqual(info.departure?.month, 7)
        XCTAssertEqual(info.departure?.day, 10)
        XCTAssertEqual(info.departure?.hour, 8)
        XCTAssertEqual(info.departure?.minute, 30)
        // 到达：带年份但缺时区，各部件按字面抽出（不做时区偏移）
        XCTAssertEqual(info.arrival?.year, 2026)
        XCTAssertEqual(info.arrival?.hour, 13)
        XCTAssertEqual(info.arrival?.minute, 0)
    }

    // MARK: - 收藏（走正则，不调 LLM）

    func testBookmarkGoesThroughRuleParser() async throws {
        let transport = MockTransport { _ in (Data(), 200) }
        let p = LLMStructuredParser(config: .claude(apiKey: "sk-test"), transport: transport)
        let result = try await p.parse("分享一篇好文章 https://example.com/article")

        guard case .bookmark(let info) = try XCTUnwrap(result).payload else { return XCTFail() }
        XCTAssertEqual(info.url.absoluteString, "https://example.com/article")
        XCTAssertEqual(info.title, "分享一篇好文章")
        XCTAssertEqual(try XCTUnwrap(result).confidence, 0.95)
        // 收藏不该调 LLM
        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty, "收藏走正则，不应发起 LLM 请求")
    }

    // MARK: - 待办/自由文本 → nil（交给 fallback）

    func testTodoTextReturnsNil() async throws {
        let transport = MockTransport { _ in (Data(), 200) }
        let p = LLMStructuredParser(config: .claude(apiKey: "sk-test"), transport: transport)
        // 无快递/行程/URL 关键词 → classify 为 nil → 返回 nil
        let result = try await p.parse("明天下午三点前把周报发给老板，记得预约体检")
        XCTAssertNil(result, "自由文本待办应交给管线 fallback")
        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty, "未分类文本不应调 LLM")
    }

    func testEmptyTextReturnsNil() async throws {
        let p = structuredParser { _ in (Data(), 200) }
        let result = try await p.parse("   \n  ")
        XCTAssertNil(result)
    }

    // MARK: - 管线集成：结构化主 + 待办兜底

    func testPipelineStructuredPrimaryTodoFallback() async throws {
        // primary(结构化)对自由文本返回 nil → 落到 fallback(待办抽取)
        let structuredTransport = MockTransport { _ in (Data(), 200) }
        let todoInner = #"{"todos":[{"title":"给妈妈买生日礼物","due":null}]}"#
        let todoTransport = MockTransport { _ in
            (try! JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": todoInner]]]), 200)
        }
        let pipeline = ParserPipeline(
            primary: LLMStructuredParser(config: .claude(apiKey: "sk"), transport: structuredTransport),
            fallback: LLMTodoParser(config: .claude(apiKey: "sk"), transport: todoTransport))
        let result = try await pipeline.parse("下周之前给妈妈买生日礼物别忘了")

        guard case .todos(let todos) = try XCTUnwrap(result).payload else { return XCTFail() }
        XCTAssertEqual(todos.first?.title, "给妈妈买生日礼物")
    }
}
