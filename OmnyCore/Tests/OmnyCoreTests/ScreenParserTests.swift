import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import OmnyCore

/// ScreenParser：截图 OCR 脏文本 → 多条多类。
/// 验收基线来自真实场景——一张备忘录截图同时含一条待办和一条快递，夹杂时间戳/"无更多文本"/界面噪声。
private func envelope(_ inner: String) -> Data {
    try! JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": inner]]])
}

final class ScreenParserTests: XCTestCase {

    /// 用户实测的脏数据：整段被旧管线误判为"快递"，待办被吞、快递缺字段。
    let dirtyOCR = """
    22:434
    今8
    备忘录
    2个备忘录
    今天
    明天记得去天府广场拿你买的水果
    22:40 无更多文本
    【韵达识别测试快递】凭6-28-93136到经开区某某驿站取运单尾号93136包裹
    22:39 无更多文本
    搜索
    """

    // MARK: - LLM 路径：一次抽出多条多类

    func testExtractsMixedTodoAndPackage() async throws {
        // 模拟 LLM 从脏文本抽出：1 条待办 + 1 条快递，噪声被忽略
        let inner = #"""
        {"todos":[{"title":"去天府广场拿水果","due":"2026-07-11T00:00:00+08:00"}],
         "packages":[{"carrier":"韵达快递","trackingNumber":null,"trackingTail":"93136",
                      "pickupCode":"6-28-93136","station":"经开区某某驿站"}],
         "trips":[]}
        """#
        let parser = ScreenParser(config: .claude(apiKey: "sk-test"),
                                  transport: MockTransport { _ in (envelope(inner), 200) })
        let result = try await parser.parse(dirtyOCR)

        // 多条多类 → mixed
        guard case .mixed(let payloads) = try XCTUnwrap(result).payload else {
            return XCTFail("应为 mixed")
        }
        XCTAssertEqual(payloads.count, 2)

        // 快递条目字段完整（待办不再被吞、快递不再缺字段）
        let pkg = payloads.compactMap { p -> PackageInfo? in
            if case .package(let i) = p { return i }; return nil
        }.first
        XCTAssertEqual(pkg?.carrier, "韵达快递")
        XCTAssertEqual(pkg?.pickupCode, "6-28-93136")
        XCTAssertEqual(pkg?.trackingTail, "93136")
        XCTAssertEqual(pkg?.station, "经开区某某驿站")
        XCTAssertEqual(pkg?.status, .awaitingPickup)

        // 待办条目
        let todos = payloads.compactMap { p -> [TodoInfo]? in
            if case .todos(let t) = p { return t }; return nil
        }.first
        XCTAssertEqual(todos?.first?.title, "去天府广场拿水果")
    }

    /// 展平：mixed 能被 Ingestor 递归展开成逐条单类
    func testMixedFlattens() async throws {
        let inner = #"""
        {"todos":[{"title":"交房租","due":null}],
         "packages":[{"carrier":"顺丰速运","trackingNumber":null,"trackingTail":null,"pickupCode":"1-2-3","station":null}],
         "trips":[{"kind":"train","number":"G101","departure":null,"departurePlace":null,"arrival":null,"arrivalPlace":null,"seat":null}]}
        """#
        let parser = ScreenParser(config: .claude(apiKey: "sk-test"),
                                  transport: MockTransport { _ in (envelope(inner), 200) })
        let result = try await parser.parse("...")
        let flat = try XCTUnwrap(result).payload.flattened
        XCTAssertEqual(flat.count, 3)
        XCTAssertEqual(Set(flat.map(\.itemType)), [.todo, .package, .trip])
    }

    /// 只有一类一条时不包 mixed，退化成单类结果
    func testSingleItemNotWrappedInMixed() async throws {
        let inner = #"{"todos":[{"title":"买牛奶","due":null}],"packages":[],"trips":[]}"#
        let parser = ScreenParser(config: .claude(apiKey: "sk-test"),
                                  transport: MockTransport { _ in (envelope(inner), 200) })
        let result = try await parser.parse("买牛奶")
        guard case .todos(let todos) = try XCTUnwrap(result).payload else {
            return XCTFail("单条待办应为 .todos，不包 mixed")
        }
        XCTAssertEqual(todos.count, 1)
    }

    /// 全是噪声/空 → nil
    func testAllEmptyReturnsNil() async throws {
        let inner = #"{"todos":[],"packages":[],"trips":[]}"#
        let parser = ScreenParser(config: .claude(apiKey: "sk-test"),
                                  transport: MockTransport { _ in (envelope(inner), 200) })
        let result = try await parser.parse("22:40 无更多文本 搜索")
        XCTAssertNil(result)
    }

    /// 字段全空的快递条目被丢弃（不产出空快递卡）
    func testEmptyPackageItemDropped() async throws {
        let inner = #"""
        {"todos":[],
         "packages":[{"carrier":null,"trackingNumber":null,"trackingTail":null,"pickupCode":null,"station":null}],
         "trips":[]}
        """#
        let parser = ScreenParser(config: .claude(apiKey: "sk-test"),
                                  transport: MockTransport { _ in (envelope(inner), 200) })
        let result = try await parser.parse("some noise")
        XCTAssertNil(result, "空快递条目应被丢弃，无有效条目则 nil")
    }

    // MARK: - 降级路径：无 LLM 时按行走规则

    func testFallbackWithoutLLMExtractsPackageByLine() async throws {
        // config 为 nil → 纯规则降级
        let parser = ScreenParser(config: nil)
        let result = try await parser.parse(dirtyOCR)

        // 规则能从快递那行抠出快递（尾号那行完整时）；待办行规则识别不了（预期）
        let r = try XCTUnwrap(result, "降级应至少抠出快递行")
        let payloads = r.payload.flattened
        let pkg = payloads.compactMap { p -> PackageInfo? in
            if case .package(let i) = p { return i }; return nil
        }.first
        XCTAssertEqual(pkg?.carrier, "韵达快递")
        XCTAssertEqual(pkg?.pickupCode, "6-28-93136")
        // 降级置信度偏低 → 下游标 needsReview
        XCTAssertLessThan(r.confidence, 0.8)
    }

    func testFallbackNoLLMNoStructuredContentReturnsNil() async throws {
        let parser = ScreenParser(config: nil)
        // 纯待办文本，规则识别不了 → 降级返回 nil（上层把原文兜进需处理）
        let result = try await parser.parse("明天记得去天府广场拿你买的水果")
        XCTAssertNil(result)
    }

    /// 关键回归：配了 LLM 但 LLM 请求失败（网络/端点/超时）时，回退到规则降级，
    /// 纯净快递仍能抠出落库，而不是抛错 → nil → 全进需处理。
    func testLLMFailureFallsBackToRules() async throws {
        // LLM 返回 500 → send 抛错 → 应回退规则
        let parser = ScreenParser(config: .claude(apiKey: "sk-test"),
                                  transport: MockTransport { _ in (Data("boom".utf8), 500) })
        let result = try await parser.parse("【韵达快递】凭6-28-9336到金正米业取运单尾号9336包裹")
        let r = try XCTUnwrap(result, "LLM 失败应回退规则，纯净快递不应丢")
        let pkg = r.payload.flattened.compactMap { p -> PackageInfo? in
            if case .package(let i) = p { return i }; return nil
        }.first
        XCTAssertEqual(pkg?.carrier, "韵达快递")
        XCTAssertEqual(pkg?.pickupCode, "6-28-9336")
        XCTAssertLessThan(r.confidence, 0.8, "规则降级为低置信")
    }

    /// LLM 成功但一条都没抽出 → 也用规则兜一次
    func testLLMEmptyResultFallsBackToRules() async throws {
        let inner = #"{"todos":[],"packages":[],"trips":[]}"#
        let parser = ScreenParser(config: .claude(apiKey: "sk-test"),
                                  transport: MockTransport { _ in (envelope(inner), 200) })
        // LLM 抽空，但规则能命中这条快递
        let result = try await parser.parse("【韵达快递】凭6-28-9336到金正米业取运单尾号9336包裹")
        let r = try XCTUnwrap(result, "LLM 抽空应回退规则")
        XCTAssertEqual(r.payload.flattened.first?.itemType, .package)
    }
}
