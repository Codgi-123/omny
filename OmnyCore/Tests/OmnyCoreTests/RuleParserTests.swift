import XCTest
@testable import OmnyCore

/// 测试样本仿照真实短信模板编写。
/// 后续请把自己手机里的真实短信（脱敏后）补充进来，这是提升规则覆盖率最有效的方式。
final class RuleParserTests: XCTestCase {
    let parser = RuleParser()

    // MARK: - 快递

    func testShunfengWithFengchao() throws {
        let text = "【顺丰速运】您的快件SF1234567890123已由快递员派送，取件码8-3-9012，已放至丰巢智能柜，请及时领取。"
        let result = try XCTUnwrap(parser.parseSync(text))
        guard case .package(let info) = result.payload else { return XCTFail("应识别为快递") }
        XCTAssertEqual(info.carrier, "顺丰速运")
        XCTAssertEqual(info.trackingNumber, "SF1234567890123")
        XCTAssertEqual(info.pickupCode, "8-3-9012")
        XCTAssertEqual(info.station, "丰巢智能柜")
        XCTAssertGreaterThanOrEqual(result.confidence, 0.8)
    }

    func testCainiaoStation() throws {
        let text = "【菜鸟驿站】您的中通快递78912345678901已到河畔小区菜鸟驿站，凭取件码3-2-2011领取，营业时间9:00-21:00。"
        let result = try XCTUnwrap(parser.parseSync(text))
        guard case .package(let info) = result.payload else { return XCTFail("应识别为快递") }
        XCTAssertEqual(info.carrier, "中通快递")
        XCTAssertEqual(info.trackingNumber, "78912345678901")
        XCTAssertEqual(info.pickupCode, "3-2-2011")
        XCTAssertEqual(info.station, "河畔小区菜鸟驿站")
    }

    func testJingdongDelivered() throws {
        let text = "【京东】您的订单已由京东快递派送，运单号JDVA12345678901，如有疑问请联系配送员。"
        let result = try XCTUnwrap(parser.parseSync(text))
        guard case .package(let info) = result.payload else { return XCTFail("应识别为快递") }
        XCTAssertEqual(info.carrier, "京东物流")
        XCTAssertEqual(info.trackingNumber, "JDVA12345678901")
    }

    func testPackageWithoutTrackingNumberLowConfidence() throws {
        let text = "【某驿站】您有一个包裹待取件，请尽快到店。"
        let result = try XCTUnwrap(parser.parseSync(text))
        guard case .package = result.payload else { return XCTFail("应识别为快递") }
        XCTAssertLessThan(result.confidence, 0.8, "缺关键字段应低置信度，落给 LLM 兜底")
    }

    // MARK: - 快递状态推断

    func testStatusAwaitingPickup() throws {
        // 到站短信常带"已由快递员派送"字样，不能被判成派送中
        let text = "【顺丰速运】您的快件SF1234567890123已由快递员派送，取件码8-3-9012，已放至丰巢智能柜，请及时领取。"
        let result = try XCTUnwrap(parser.parseSync(text))
        guard case .package(let info) = result.payload else { return XCTFail() }
        XCTAssertEqual(info.status, .awaitingPickup)
    }

    func testStatusPickedUp() throws {
        let text = "【菜鸟驿站】您的包裹78912345678901已取出，感谢使用菜鸟驿站，期待再次为您服务。"
        let result = try XCTUnwrap(parser.parseSync(text))
        guard case .package(let info) = result.payload else { return XCTFail() }
        XCTAssertEqual(info.status, .pickedUp)
        XCTAssertEqual(info.trackingNumber, "78912345678901")
    }

    func testStatusSigned() throws {
        let text = "【京东】您的快递运单号JDVA12345678901已签收，感谢您在京东购物。"
        let result = try XCTUnwrap(parser.parseSync(text))
        guard case .package(let info) = result.payload else { return XCTFail() }
        XCTAssertEqual(info.status, .pickedUp)
    }

    func testStatusOutForDelivery() throws {
        let text = "【中通快递】您的快件78912345678901正在派送中，快递员小王 13800000000，预计送达时间18:00前。"
        let result = try XCTUnwrap(parser.parseSync(text))
        guard case .package(let info) = result.payload else { return XCTFail() }
        XCTAssertEqual(info.status, .outForDelivery)
    }

    func testStatusInTransit() throws {
        let text = "【圆通速递】您的快件YT7512345678901已被揽收，正在运输途中，请耐心等待。"
        let result = try XCTUnwrap(parser.parseSync(text))
        guard case .package(let info) = result.payload else { return XCTFail() }
        XCTAssertEqual(info.status, .inTransit)
        XCTAssertEqual(info.carrier, "圆通速递")
    }

    func testStatusOnlyMovesForward() {
        // 入库合并时依赖这个比较语义：状态只前进不回退
        XCTAssertLessThan(PackageStatus.inTransit, .outForDelivery)
        XCTAssertLessThan(PackageStatus.outForDelivery, .awaitingPickup)
        XCTAssertLessThan(PackageStatus.awaitingPickup, .pickedUp)
    }

    // MARK: - 行程

    func testTrain12306() throws {
        let text = "【铁路12306】订单EB12345678，张三已购05月20日G101次列车7车12A号，北京南站09:05开。请提前取票，携带有效证件进站乘车。"
        let result = try XCTUnwrap(parser.parseSync(text))
        guard case .trip(let info) = result.payload else { return XCTFail("应识别为行程") }
        XCTAssertEqual(info.kind, .train)
        XCTAssertEqual(info.number, "G101")
        XCTAssertEqual(info.departure?.month, 5)
        XCTAssertEqual(info.departure?.day, 20)
        XCTAssertEqual(info.departure?.hour, 9)
        XCTAssertEqual(info.departure?.minute, 5)
        XCTAssertEqual(info.departurePlace, "北京南")
        XCTAssertEqual(info.seat, "7车12A号")
    }

    func testTrainTicketGateAndSeatClass() throws {
        let text = "【铁路12306】您已购07月18日G8511次列车05车12F号，二等座，成都东站09:12开，检票口A6。"
        let result = try XCTUnwrap(parser.parseSync(text))
        guard case .trip(let info) = result.payload else { return XCTFail("应识别为行程") }
        XCTAssertEqual(info.number, "G8511")
        XCTAssertEqual(info.seat, "05车12F号")
        XCTAssertEqual(info.ticketGate, "A6")
        XCTAssertEqual(info.seatClass, "二等座")
    }

    func testFlightAirChina() throws {
        let text = "【中国国航】您预订的05月21日CA1831航班将于08:00从北京首都机场T3起飞，10:15到达上海虹桥机场T2，请提前2小时到达机场办理登机手续。"
        let result = try XCTUnwrap(parser.parseSync(text))
        guard case .trip(let info) = result.payload else { return XCTFail("应识别为行程") }
        XCTAssertEqual(info.kind, .flight)
        XCTAssertEqual(info.number, "CA1831")
        XCTAssertEqual(info.departure?.month, 5)
        XCTAssertEqual(info.departure?.day, 21)
        XCTAssertEqual(info.departure?.hour, 8)
        XCTAssertEqual(info.departure?.minute, 0)
        XCTAssertEqual(info.departurePlace, "北京首都机场T3")
        XCTAssertEqual(info.arrival?.hour, 10)
        XCTAssertEqual(info.arrival?.minute, 15)
        XCTAssertEqual(info.arrivalPlace, "上海虹桥机场T2")
    }

    func testTrainKeywordBeatsOrderNumber() throws {
        // 订单号 EB12345678 不应被误认为快递单号
        let text = "【铁路12306】订单EB12345678，您已购06月01日D3082次列车2车15F号，杭州东站14:32开。"
        let result = try XCTUnwrap(parser.parseSync(text))
        guard case .trip(let info) = result.payload else { return XCTFail("应识别为行程而非快递") }
        XCTAssertEqual(info.number, "D3082")
    }

    // MARK: - 收藏

    func testBookmarkXLink() throws {
        let text = "https://x.com/karpathy/status/1234567890123456789"
        let result = try XCTUnwrap(parser.parseSync(text))
        guard case .bookmark(let info) = result.payload else { return XCTFail("应识别为收藏") }
        XCTAssertEqual(info.url.host(), "x.com")
        XCTAssertNil(info.title)
    }

    func testBookmarkWithDescription() throws {
        let text = "看看这篇 https://example.com/article?id=42 挺有意思的"
        let result = try XCTUnwrap(parser.parseSync(text))
        guard case .bookmark(let info) = result.payload else { return XCTFail("应识别为收藏") }
        XCTAssertEqual(info.url.absoluteString, "https://example.com/article?id=42")
        XCTAssertEqual(info.title, "看看这篇  挺有意思的")
    }

    // MARK: - 规则覆盖不了的

    func testFreeTextReturnsNil() {
        XCTAssertNil(parser.parseSync("明天下午三点前把周报发给老板"), "自由文本应返回 nil 交给 LLM")
        XCTAssertNil(parser.parseSync(""), "空文本返回 nil")
        XCTAssertNil(parser.parseSync("验证码 384756，5分钟内有效。"), "验证码短信不该被误收")
    }

    // MARK: - 管线

    func testPipelineFallsBackToLLM() async throws {
        struct StubLLM: Parser {
            func parse(_ text: String) async throws -> ParseResult? {
                ParseResult(payload: .todos([TodoInfo(title: "发周报")]), confidence: 0.85, rawText: text)
            }
        }
        let pipeline = ParserPipeline(primary: RuleParser(), fallback: StubLLM())
        let result = try await pipeline.parse("明天下午三点前把周报发给老板")
        guard case .todos(let todos) = try XCTUnwrap(result).payload else { return XCTFail() }
        XCTAssertEqual(todos.first?.title, "发周报")
    }

    func testPipelineDegradesGracefullyWhenLLMUnavailable() async throws {
        struct FailingLLM: Parser {
            struct Unavailable: Error {}
            func parse(_ text: String) async throws -> ParseResult? { throw Unavailable() }
        }
        let pipeline = ParserPipeline(primary: RuleParser(), fallback: FailingLLM())
        // 规则低置信度命中 + LLM 挂了 → 降级用规则结果，不抛错
        let result = try await pipeline.parse("【某驿站】您有一个包裹待取件，请尽快到店。")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.payload.itemType, .package)
    }
}
