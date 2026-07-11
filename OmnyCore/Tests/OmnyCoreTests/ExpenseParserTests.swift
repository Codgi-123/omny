import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import OmnyCore

/// 把一段 JSON 文本包成 Claude Messages 响应
private func claudeExpenseEnvelope(_ inner: String) -> Data {
    try! JSONSerialization.data(withJSONObject: [
        "content": [["type": "text", "text": inner]],
    ])
}

/// 记账解析：分类正则（classify/extractExpense）+ 结构化 LLM（parseExpense）+ 两级打标。
final class ExpenseParserTests: XCTestCase {

    // MARK: - 分类：双命中判定

    func testClassifyExpenseNeedsAmountAndVerb() {
        // 金额 + 交易动词 → expense
        XCTAssertEqual(RuleParser.classify("您尾号1234的储蓄卡消费128.50元"), .expense)
        XCTAssertEqual(RuleParser.classify("工资入账8500.00元"), .expense)
        XCTAssertEqual(RuleParser.classify("微信支付￥25.00"), .expense)
    }

    func testClassifyRejectsAmountWithoutVerb() {
        // 有金额没交易动词 → 不判为 expense（避免误伤）
        XCTAssertNil(RuleParser.classify("这件商品128元很划算"))
    }

    func testClassifyRejectsVerbWithoutAmount() {
        // 有交易动词没金额 → 不判为 expense
        XCTAssertNil(RuleParser.classify("请尽快完成本月还款"))
    }

    func testPackagePriorityOverExpense() {
        // 快递短信偶尔带金额，但快递关键词更强，应判快递而非记账
        XCTAssertEqual(RuleParser.classify("【顺丰速运】您的到付快递需支付12.00元，凭取件码3-2-2011取件"), .package)
    }

    // MARK: - 正则降级：extractExpense

    func testExtractExpenseAmountAndTail() throws {
        let info = try XCTUnwrap(RuleParser.extractExpense("您尾号1234的储蓄卡消费128.50元，余额2000.00元"))
        XCTAssertEqual(info.amount, Decimal(string: "128.50"))
        XCTAssertEqual(info.cardTail, "1234")
        XCTAssertEqual(info.direction, .expense)
    }

    func testExtractExpenseIncomeDirection() throws {
        let info = try XCTUnwrap(RuleParser.extractExpense("您尾号5678的账户工资入账8500.00元"))
        XCTAssertEqual(info.direction, .income)
        XCTAssertEqual(info.amount, Decimal(string: "8500.00"))
    }

    func testExtractExpenseYenPrefix() throws {
        let info = try XCTUnwrap(RuleParser.extractExpense("微信支付￥1,234.56"))
        XCTAssertEqual(info.amount, Decimal(string: "1234.56"))
    }

    // MARK: - LLM 结构化：parseExpense

    private func expenseParser(_ inner: String) -> LLMStructuredParser {
        LLMStructuredParser(config: .claude(apiKey: "sk-test"),
                            transport: MockTransport { _ in (claudeExpenseEnvelope(inner), 200) })
    }

    func testLLMExpenseExtractsFields() async throws {
        let inner = #"""
        {"direction":"expense","amount":"128.50","merchant":"美团外卖",
         "occurredAt":"2026-07-11T12:30:00","channel":"招商银行","cardTail":"1234"}
        """#
        let result = try await expenseParser(inner).parse("您尾号1234的招行卡消费128.50元(美团外卖)")
        guard case .expense(let info) = try XCTUnwrap(result).payload else { return XCTFail() }
        XCTAssertEqual(info.amount, Decimal(string: "128.50"))
        XCTAssertEqual(info.merchant, "美团外卖")
        XCTAssertEqual(info.channel, "招商银行")
        XCTAssertEqual(info.cardTail, "1234")
        XCTAssertEqual(info.direction, .expense)
        // 分类不由结构化 LLM 打，应留空交给 categorizer
        XCTAssertNil(info.categoryMajor)
        XCTAssertNil(info.categorySub)
        XCTAssertEqual(try XCTUnwrap(result).confidence, 0.9)
    }

    func testLLMExpenseUsesStringAmountForPrecision() async throws {
        // 金额用字符串传避免浮点精度；0.1+0.2 类问题不出现
        let inner = #"{"direction":"expense","amount":"0.30","merchant":null,"occurredAt":null,"channel":null,"cardTail":null}"#
        let result = try await expenseParser(inner).parse("消费0.30元")
        guard case .expense(let info) = try XCTUnwrap(result).payload else { return XCTFail() }
        XCTAssertEqual(info.amount, Decimal(string: "0.30"))
    }

    func testLLMExpenseEmptyReturnsNil() async throws {
        // 金额/商户/尾号全空 → nil，不产空账单卡
        let inner = #"{"direction":"expense","amount":null,"merchant":null,"occurredAt":null,"channel":null,"cardTail":null}"#
        let result = try await expenseParser(inner).parse("您有一笔交易待确认")
        XCTAssertNil(result)
    }

    func testLLMExpenseUsesExpenseSchemaAndPrompt() async throws {
        let inner = #"{"direction":"expense","amount":"1.00","merchant":null,"occurredAt":null,"channel":null,"cardTail":null}"#
        let transport = MockTransport { _ in (claudeExpenseEnvelope(inner), 200) }
        let p = LLMStructuredParser(config: .claude(apiKey: "sk-test"), transport: transport)
        _ = try await p.parse("消费1.00元 支付成功")

        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        XCTAssertEqual((body?["system"] as? String)?.contains("记账"), true)
        let schema = ((body?["output_config"] as? [String: Any])?["format"] as? [String: Any])?["schema"] as? [String: Any]
        let props = schema?["properties"] as? [String: Any]
        XCTAssertNotNil(props?["direction"])
        XCTAssertNotNil(props?["amount"])
    }

    // MARK: - 两级消费分类

    func testCategorizerFlatten() {
        let pool = ["餐饮": ["早餐", "午餐"], "交通": ["打车"]]
        XCTAssertEqual(LLMExpenseCategorizer.flatten(pool), ["交通/打车", "餐饮/早餐", "餐饮/午餐"])
    }

    func testCategorizerPicksLegalCombination() async throws {
        let inner = #"{"category":"餐饮/午餐"}"#
        let cat = LLMExpenseCategorizer(config: .claude(apiKey: "sk"),
                                        transport: MockTransport { _ in (claudeExpenseEnvelope(inner), 200) })
        let picked = try await cat.classify("美团外卖 128元", pool: ["餐饮": ["早餐", "午餐"], "交通": ["打车"]])
        XCTAssertEqual(picked?.major, "餐饮")
        XCTAssertEqual(picked?.sub, "午餐")
    }

    func testCategorizerRejectsOutOfPool() async throws {
        // 模型越界返回不在候选里的组合 → nil
        let inner = #"{"category":"餐饮/夜宵"}"#
        let cat = LLMExpenseCategorizer(config: .claude(apiKey: "sk"),
                                        transport: MockTransport { _ in (claudeExpenseEnvelope(inner), 200) })
        let picked = try await cat.classify("烧烤", pool: ["餐饮": ["早餐", "午餐"]])
        XCTAssertNil(picked)
    }
}
