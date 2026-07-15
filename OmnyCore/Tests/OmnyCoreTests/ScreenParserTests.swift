import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import OmnyCore

/// ScreenParser：截图 OCR 脏文本 → 三层管线（规则路由 → LLM 分类兜底 → 分类专用抽取）。
/// 用 MockTransport 按请求的 system prompt 分流响应，白盒断言「发的是哪个 prompt」。
private func envelope(_ inner: String) -> Data {
    try! JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": inner]]])
}

/// 请求体里的 system prompt 判别：分类请求 / 各类专用抽取请求
private func promptKind(of request: URLRequest) -> String {
    let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    if body.contains("属于哪一类") { return "classify" }
    if body.contains("提取快递物流信息") { return "package" }
    if body.contains("提取行程信息") { return "trip" }
    if body.contains("提取待办事项") { return "todo" }
    if body.contains("提取交易记录") { return "expense" }
    return "unknown"
}

final class ScreenParserTests: XCTestCase {

    /// 用户实测的脏数据：一屏同时有备忘录待办和快递通知。
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

    // MARK: - 第一层路由 + 第三层专用抽取

    /// 备忘录+快递混合截图：混合暂不做——路由取最高分类别（快递 7 > 待办 5），
    /// 只发快递专用 prompt、只抽快递（待办被舍弃是当前产品决定）。
    func testMultiSignalRoutesTopCategoryAndExtractsPackage() async throws {
        let inner = #"{"packages":[{"carrier":"韵达快递","pickupCode":"6-28-93136","station":"经开区某某驿站"}]}"#
        let transport = MockTransport { _ in (envelope(inner), 200) }
        let parser = ScreenParser(config: .claude(apiKey: "sk-test"), transport: transport)
        let result = try await parser.parse(dirtyOCR)

        guard case .package(let info) = try XCTUnwrap(result).payload else {
            return XCTFail("应抽出单条快递")
        }
        XCTAssertEqual(info.carrier, "韵达快递")
        XCTAssertEqual(info.pickupCode, "6-28-93136")
        XCTAssertEqual(info.station, "经开区某某驿站")
        XCTAssertEqual(info.status, .awaitingPickup, "状态由正则从原文措辞推断")

        // 白盒：规则路由直达快递抽取，一次调用、没有分类请求
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map(promptKind(of:)), ["package"])
    }

    /// 支付成功页截图 → 记账。字段瘦身后只抽方向/金额/时间。
    func testExtractsExpenseFromPaymentScreenshot() async throws {
        let paymentOCR = """
        账单
        美团
        钢管厂五区小郡肝串串香（新华公园总店）
        -19.00
        支付成功
        支付时间 2026年7月10日 19:41:59
        商户全称 成都五区顾大妈餐饮管理有限公司
        支付方式 成都银行储蓄卡（8164）
        交易单号 4200003170202607105997164744
        商户单号 0461368606697779658001632
        """
        let inner = #"{"expenses":[{"direction":"expense","amount":"19.00","occurredAt":"2026-07-10T19:41:59"}]}"#
        let transport = MockTransport { _ in (envelope(inner), 200) }
        let parser = ScreenParser(config: .claude(apiKey: "sk-test"), transport: transport)
        let result = try await parser.parse(paymentOCR)

        guard case .expense(let info) = try XCTUnwrap(result).payload else {
            return XCTFail("应抽出 expense，而非落未分类")
        }
        XCTAssertEqual(info.direction, .expense)
        XCTAssertEqual(info.amount, Decimal(string: "19.00"))
        XCTAssertEqual(info.occurredAt?.month, 7)
        XCTAssertEqual(info.occurredAt?.day, 10)
        // 瘦身后不再抽取的字段保持为空；分类留给 categorizer
        XCTAssertNil(info.merchant)
        XCTAssertNil(info.txnID)
        XCTAssertNil(info.categoryMajor)

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map(promptKind(of:)), ["expense"], "指纹+身份锚点应直达记账抽取")
    }

    /// 方向宽容解析：模型输出 "income" 变体（大小写/中文）不被静默当成支出
    func testExpenseIncomeDirectionLenient() async throws {
        let receiveOCR = """
        红包详情
        +5.00
        已存入零钱
        转账单号 2100003990100051104730174585
        """
        let inner = #"{"expenses":[{"direction":"Income","amount":"5.00","occurredAt":null}]}"#
        let parser = ScreenParser(config: .claude(apiKey: "sk-test"),
                                  transport: MockTransport { _ in (envelope(inner), 200) })
        let result = try await parser.parse(receiveOCR)
        guard case .expense(let info) = try XCTUnwrap(result).payload else {
            return XCTFail("应抽出 expense")
        }
        XCTAssertEqual(info.direction, .income)
    }

    /// 酒店/民宿订单页 → 行程 kind=hotel，departure/arrival 映射入住/离店
    func testExtractsHotelTrip() async throws {
        let hotelOCR = """
        ～分享房源
        四 联系房东
        10月4日周六-10月6日周一（2晚
        14:00后入住
        12:00前离店
        金桂苑整套民宿
        整套洋房大床房·含双早
        德清县莫干山镇劳岭村108号
        """
        let inner = #"""
        {"trips":[{"kind":"hotel","number":null,"departure":"10-04T14:00","departurePlace":"金桂苑整套民宿",
                   "arrival":"10-06T12:00","arrivalPlace":null,"seat":"整套洋房大床房·含双早",
                   "ticketGate":null,"seatClass":null,"address":"德清县莫干山镇劳岭村108号"}]}
        """#
        let transport = MockTransport { _ in (envelope(inner), 200) }
        let parser = ScreenParser(config: .claude(apiKey: "sk-test"), transport: transport)
        let result = try await parser.parse(hotelOCR)

        guard case .trip(let info) = try XCTUnwrap(result).payload else {
            return XCTFail("应抽出 hotel 行程")
        }
        XCTAssertEqual(info.kind, .hotel)
        XCTAssertEqual(info.number, "", "酒店无班次号")
        XCTAssertEqual(info.departurePlace, "金桂苑整套民宿")
        XCTAssertEqual(info.seat, "整套洋房大床房·含双早")
        XCTAssertEqual(info.address, "德清县莫干山镇劳岭村108号")
        XCTAssertEqual(info.departure?.month, 10)
        XCTAssertEqual(info.departure?.day, 4)
        XCTAssertEqual(info.departure?.hour, 14)

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map(promptKind(of:)), ["trip"])
    }

    /// 记账金额抽不出 → 该条被硬校验丢弃；规则也兜不出 → 整体 nil，不产空账单卡
    func testExpenseWithoutAmountDropped() async throws {
        let paymentOCR = """
        支付成功
        某商户
        交易单号 4200003170202607105997164744
        """
        let inner = #"{"expenses":[{"direction":"expense","amount":null,"occurredAt":null}]}"#
        let parser = ScreenParser(config: .claude(apiKey: "sk-test"),
                                  transport: MockTransport { _ in (envelope(inner), 200) })
        let result = try await parser.parse(paymentOCR)
        XCTAssertNil(result, "无金额的记账条目应被丢弃")
    }

    /// 字段全空的快递条目被硬校验丢弃；规则也兜不出（行太短）→ nil，不产空快递卡
    func testEmptyPackageItemDropped() async throws {
        let inner = #"{"packages":[{"carrier":null,"pickupCode":null,"station":null}]}"#
        let parser = ScreenParser(config: .claude(apiKey: "sk-test"),
                                  transport: MockTransport { _ in (envelope(inner), 200) })
        // "丰巢" 指纹+词袋直达快递路由，但抽取全空
        let result = try await parser.parse("丰巢")
        XCTAssertNil(result, "空快递条目应被丢弃，无有效条目则 nil")
    }

    // MARK: - 第二层：LLM 分类兜底（无规则信号的自由文本）

    /// 纯待办文本无规则信号 → 走 LLM 分类（todo）→ 待办专用抽取；单条不包 mixed
    func testNoSignalClassifiesThenExtractsTodo() async throws {
        let transport = MockTransport { request in
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            if body.contains("属于哪一类") {
                return (envelope(#"{"category":"todo","reason":"购物备忘"}"#), 200)
            }
            return (envelope(#"{"todos":[{"title":"买牛奶","due":null}]}"#), 200)
        }
        let parser = ScreenParser(config: .claude(apiKey: "sk-test"), transport: transport)
        let result = try await parser.parse("买牛奶")

        guard case .todos(let todos) = try XCTUnwrap(result).payload else {
            return XCTFail("单条待办应为 .todos，不包 mixed")
        }
        XCTAssertEqual(todos.count, 1)
        XCTAssertEqual(todos.first?.title, "买牛奶")

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map(promptKind(of:)), ["classify", "todo"], "先分类后抽取")
    }

    /// 分类判 none（纯噪声）→ 不再发抽取请求，规则也兜不出 → nil
    func testClassifyNoneReturnsNil() async throws {
        let transport = MockTransport { _ in
            (envelope(#"{"category":"none","reason":"纯界面噪声"}"#), 200)
        }
        let parser = ScreenParser(config: .claude(apiKey: "sk-test"), transport: transport)
        let result = try await parser.parse("22:40 无更多文本 搜索")
        XCTAssertNil(result)

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map(promptKind(of:)), ["classify"], "none 后不应再发抽取请求")
    }

    // MARK: - 降级路径：无 LLM / LLM 失败时按行走规则

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

    /// 规则降级一屏多行多类 → mixed，能被 Ingestor 展开逐条落库
    func testFallbackMixedFlattens() async throws {
        let parser = ScreenParser(config: nil)
        let twoLines = """
        【韵达快递】凭6-28-9336到金正米业取运单尾号9336包裹
        您购买的5月1日G101次列车成都东站08:00开二等座车票
        """
        let result = try await parser.parse(twoLines)
        let flat = try XCTUnwrap(result).payload.flattened
        XCTAssertEqual(flat.count, 2)
        XCTAssertEqual(Set(flat.map(\.itemType)), [.package, .trip])
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
