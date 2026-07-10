import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import OmnyCore

/// 「空快递卡」bug 的回归测试：截图/短信来源出现只显示来源、无任何字段的快递卡。
/// 根因是 LLM 抽取返回全 null 时，旧代码仍产出 confidence=0.9 的空 package。
/// 修复后：全空返回 nil（交给兜底/降级），弱字段给低置信（下游标 needsReview）。
private func claudeEnvelope(_ inner: String) -> Data {
    try! JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": inner]]])
}

final class EmptyPackageDiagnosisTests: XCTestCase {

    /// 修复后：LLM 抽取字段全 null → parsePackage 返回 nil，不再产出空快递卡。
    func testAllNullFieldsReturnsNil() async throws {
        let allNull = #"{"carrier":null,"trackingNumber":null,"trackingTail":null,"pickupCode":null,"station":null}"#
        let p = LLMStructuredParser(config: .claude(apiKey: "sk-test"),
                                    transport: MockTransport { _ in (claudeEnvelope(allNull), 200) })
        let result = try await p.parse("【圆通快递】凭37-1-6312到成都双流区保利创智锦城店取运单尾号6312包裹")
        XCTAssertNil(result, "字段全空不应产出空快递卡，应返回 nil 交给兜底")
    }

    /// 修复后：只有弱字段(公司/驿站，无取件码/单号/尾号) → 低置信 0.6，
    /// 下游 Ingestor 会标 needsReview 让用户确认，而不是静默落成正常快递。
    func testOnlyWeakFieldsGivesLowConfidence() async throws {
        let weakOnly = #"{"carrier":"圆通速递","trackingNumber":null,"trackingTail":null,"pickupCode":null,"station":"某某驿站"}"#
        let p = LLMStructuredParser(config: .claude(apiKey: "sk-test"),
                                    transport: MockTransport { _ in (claudeEnvelope(weakOnly), 200) })
        let result = try await p.parse("【圆通快递】您的包裹已到某某驿站")
        let r = try XCTUnwrap(result)
        guard case .package(let info) = r.payload else { return XCTFail("应为 package") }
        XCTAssertEqual(info.carrier, "圆通速递")
        XCTAssertNil(info.pickupCode)
        XCTAssertLessThan(r.confidence, 0.8, "只有弱字段应低置信，触发 needsReview")
    }

    /// 修复后：有强标识字段(取件码/单号/尾号) → 高置信 0.9，正常入库。
    func testStrongFieldGivesHighConfidence() async throws {
        let strong = #"{"carrier":null,"trackingNumber":null,"trackingTail":"6312","pickupCode":"37-1-6312","station":null}"#
        let p = LLMStructuredParser(config: .claude(apiKey: "sk-test"),
                                    transport: MockTransport { _ in (claudeEnvelope(strong), 200) })
        let result = try await p.parse("【圆通快递】凭37-1-6312取运单尾号6312")
        let r = try XCTUnwrap(result)
        XCTAssertEqual(r.confidence, 0.9)
    }

    /// 现象 2 相关：LLM 抽取抛错(网络/端点/超时)时，LLMStructuredParser.parse 会抛错。
    /// 在管线里这会触发 fallback；若 fallback 也失败则降级或返回 nil。
    func testLLMErrorThrows() async throws {
        let p = LLMStructuredParser(config: .claude(apiKey: "sk-test"),
                                    transport: MockTransport { _ in (Data("boom".utf8), 500) })
        do {
            _ = try await p.parse("【圆通快递】凭37-1-6312到成都双流区保利创智锦城店取运单尾号6312包裹")
            XCTFail("HTTP 500 应抛错")
        } catch {
            // 预期抛错 → 管线会落 fallback
        }
    }

    /// 管线全景：primary(结构化)500 抛错 + fallback(待办)也抛错 → 整体行为。
    /// 验证"二次识别失败时结果如何"——这决定 Ingestor 收到什么。
    func testPipelineBothFailReturnsNilOrThrows() async throws {
        let pipeline = ParserPipeline(
            primary: LLMStructuredParser(config: .claude(apiKey: "sk"),
                                         transport: MockTransport { _ in (Data("boom".utf8), 500) }),
            fallback: LLMTodoParser(config: .claude(apiKey: "sk"),
                                    transport: MockTransport { _ in (Data("boom".utf8), 500) }))
        // primary 抛错 → 进 fallback；fallback 也抛错 → 管线 catch 里因无 primaryResult 而 rethrow
        do {
            let r = try await pipeline.parse("【圆通快递】凭37-1-6312到成都双流区保利创智锦城店取运单尾号6312包裹")
            // 若没抛错，结果应为 nil（两条路都没产出）
            XCTAssertNil(r, "两条 LLM 路径都失败时应为 nil 或抛错")
        } catch {
            // 抛错也是合理路径：Ingestor 的 do/catch 会把它转成 nil → 建未分类项进需处理
        }
    }

    /// 对照：LLM 正常抽出字段时应产出完整快递(证明链路本身没错，问题在异常/空返回处理)
    func testLLMNormalExtractionWorks() async throws {
        let ok = #"{"carrier":"圆通速递","trackingNumber":null,"trackingTail":"6312","pickupCode":"37-1-6312","station":"成都双流区保利创智锦城店"}"#
        let p = LLMStructuredParser(config: .claude(apiKey: "sk-test"),
                                    transport: MockTransport { _ in (claudeEnvelope(ok), 200) })
        let result = try await p.parse("【圆通快递】凭37-1-6312到成都双流区保利创智锦城店取运单尾号6312包裹")
        guard case .package(let info) = try XCTUnwrap(result).payload else { return XCTFail() }
        XCTAssertEqual(info.pickupCode, "37-1-6312")
        XCTAssertEqual(info.trackingTail, "6312")
        XCTAssertEqual(info.status, .awaitingPickup)
    }
}
