import XCTest
@testable import OmnyCore

/// 仿照真机短信模板编写的样本（地址/单号/取件码/手机号等均已脱敏为虚构值），
/// 是规则引擎的验收标准。保留真实短信的结构特征：取件码用"凭X到/取/领"句式、
/// 只有运单尾号、发件方与实际快递公司不一致、存放点后缀多变等。
final class RealSMSTests: XCTestCase {
    let parser = RuleParser()

    private func parsePackage(_ text: String, file: StaticString = #filePath,
                              line: UInt = #line) throws -> (PackageInfo, Double) {
        let result = try XCTUnwrap(parser.parseSync(text), "未识别", file: file, line: line)
        guard case .package(let info) = result.payload else {
            XCTFail("未识别为快递", file: file, line: line)
            throw XCTSkip()
        }
        return (info, result.confidence)
    }

    func testYuantoPingCodeStyle() throws {
        let (info, confidence) = try parsePackage(
            "【圆通快递】凭50-1-1000到示例城示例区示范花园驿站店取运单尾号1000包裹")
        XCTAssertEqual(info.carrier, "圆通速递")
        XCTAssertEqual(info.pickupCode, "50-1-1000")
        XCTAssertEqual(info.trackingTail, "1000")
        XCTAssertEqual(info.station, "示例城示例区示范花园驿站店")
        XCTAssertEqual(info.status, .awaitingPickup)
        XCTAssertGreaterThanOrEqual(confidence, 0.8)
    }

    func testShentongPingCodeStyle() throws {
        let (info, _) = try parsePackage(
            "【申通快递】凭1-2-1001到示例城示例区示范花园驿站店取运单尾号1001包裹")
        XCTAssertEqual(info.carrier, "申通快递")
        XCTAssertEqual(info.pickupCode, "1-2-1001")
        XCTAssertEqual(info.trackingTail, "1001")
    }

    func testMerchantSFTrackingNumber() throws {
        let (info, _) = try parsePackage(
            "尊敬的客户【示例店铺】：快递需要在对应的平台付费才能打印发货单【您的快递单号:SF1000000000001】")
        XCTAssertEqual(info.carrier, "顺丰速运")
        XCTAssertEqual(info.trackingNumber, "SF1000000000001")
        XCTAssertEqual(info.status, .inTransit)
    }

    func testJDSenderButZTOCarrier() throws {
        // 发件方是京东（商家），实际承运是中通
        let (info, _) = try parsePackage("【京东】70000000000001中通快递")
        XCTAssertEqual(info.carrier, "中通快递")
        XCTAssertEqual(info.trackingNumber, "70000000000001")
    }

    func testYundaStoreSenderButShentongCarrier() throws {
        // 发件方是韵达超市（代收点），实际快递是申通
        let (info, _) = try parsePackage(
            "【韵达超市】您的申通快递包裹已到示范路示例小区B区4号门车库旁右边第四个门市韵达快递，请凭8-1-1002取件")
        XCTAssertEqual(info.carrier, "申通快递")
        XCTAssertEqual(info.pickupCode, "8-1-1002")
        XCTAssertEqual(info.station, "示范路示例小区B区4号门车库旁右边第四个门市")
        XCTAssertEqual(info.status, .awaitingPickup)
    }

    func testYixiaogePlainNumericCode() throws {
        let (info, _) = try parsePackage(
            "【驿小哥】您的快递顺丰，已到示例小区四号车库旁10-1-15号顺丰门市，凭10003免费取，如有疑问可到店咨询，谢谢")
        XCTAssertEqual(info.carrier, "顺丰速运")
        XCTAssertEqual(info.pickupCode, "10003")
        XCTAssertEqual(info.station, "示例小区四号车库旁10-1-15号顺丰门市")
        XCTAssertEqual(info.status, .awaitingPickup)
    }

    func testJDTailNumberAtSFStore() throws {
        let (info, _) = try parsePackage(
            "【京东快递】快递尾号1004已放在顺丰门市，快递员电话13800000000，查看签收照片或反馈异常 example.com/a-bcd")
        XCTAssertEqual(info.carrier, "京东物流")
        XCTAssertEqual(info.trackingTail, "1004")
        XCTAssertEqual(info.station, "顺丰门市")
        XCTAssertNil(info.trackingNumber, "快递员手机号不能被误认成单号")
        XCTAssertEqual(info.status, .awaitingPickup)
    }

    func testZTOConvenienceStore() throws {
        let (info, _) = try parsePackage(
            "【中通快递】包裹已到示范路86号示例商城西门旁示例生活便利店，请凭16-3-1005领取")
        XCTAssertEqual(info.carrier, "中通快递")
        XCTAssertEqual(info.pickupCode, "16-3-1005")
        XCTAssertEqual(info.station, "示范路86号示例商城西门旁示例生活便利店")
        XCTAssertEqual(info.status, .awaitingPickup, "「请…领取」不能被误判为已领取")
    }

    func testYundaWithAddressSuffix() throws {
        let (info, _) = try parsePackage(
            "【韵达快递】凭27-3-1006到示例城示例区示范花园驿站店取货，地址：示范路13号(公寓2栋背后商铺-示例24小时无人自助超市)")
        XCTAssertEqual(info.carrier, "韵达快递")
        XCTAssertEqual(info.pickupCode, "27-3-1006")
        XCTAssertEqual(info.station, "示例城示例区示范花园驿站店")
    }

    func testStationWithOpenEndedSuffix() throws {
        // 存放点"示范米业"结尾是"业"，不在旧的后缀白名单里，曾漏提取。
        // 「凭码到…取」句式改为靠"到…取/领"这对天然边界后修正。
        let (info, _) = try parsePackage(
            "【韵达快递】凭6-28-1007到示范米业取运单尾号1007包裹")
        XCTAssertEqual(info.carrier, "韵达快递")
        XCTAssertEqual(info.pickupCode, "6-28-1007")
        XCTAssertEqual(info.trackingTail, "1007")
        XCTAssertEqual(info.station, "示范米业")
        XCTAssertEqual(info.status, .awaitingPickup)
    }

    func testHumanTypedMessageFallsToLLM() throws {
        // 快递员手打的短信，没有结构化字段，应低置信度落给 LLM 兜底
        let (info, confidence) = try parsePackage(
            "你好京东快递，示例小区B区快递到了，打你电话没接，放4号门顺丰门市的，记得拿")
        XCTAssertNil(info.pickupCode)
        XCTAssertLessThan(confidence, 0.8)
    }

    // MARK: - 银行/支付动账短信（脱敏，记账规则降级基线）

    private func parseExpense(_ text: String, file: StaticString = #filePath,
                              line: UInt = #line) throws -> (ExpenseInfo, Double) {
        let result = try XCTUnwrap(parser.parseSync(text), "未识别", file: file, line: line)
        guard case .expense(let info) = result.payload else {
            XCTFail("未识别为记账", file: file, line: line)
            throw XCTSkip()
        }
        return (info, result.confidence)
    }

    func testBankDebitTailAndAmount() throws {
        let (info, confidence) = try parseExpense(
            "【招商银行】您尾号1234的储蓄卡于07月11日12:30消费人民币128.50元，余额2000.00元")
        XCTAssertEqual(info.amount, Decimal(string: "128.50"))
        XCTAssertEqual(info.cardTail, "1234")
        XCTAssertEqual(info.direction, .expense)
        XCTAssertGreaterThanOrEqual(confidence, 0.8)
    }

    func testBankIncomeCredit() throws {
        let (info, _) = try parseExpense(
            "【工商银行】您尾号5678的账户07月10日工资入账8,500.00元")
        XCTAssertEqual(info.direction, .income)
        XCTAssertEqual(info.amount, Decimal(string: "8500.00"))
        XCTAssertEqual(info.cardTail, "5678")
    }

    func testAlipayPaymentYenPrefix() throws {
        let (info, _) = try parseExpense("您使用支付宝成功支付￥25.00，收款方示例便利店")
        XCTAssertEqual(info.amount, Decimal(string: "25.00"))
        XCTAssertEqual(info.direction, .expense)
    }

    func testCommodityPriceNotExpense() throws {
        // 有金额没交易动词，不应被判成记账
        XCTAssertNil(parser.parseSync("这件商品原价199元现价128元"))
    }
}
