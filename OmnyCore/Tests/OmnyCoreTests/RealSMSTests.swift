import XCTest
@testable import OmnyCore

/// 来自真机短信截图的真实样本（2026-07-08 提供），是规则引擎的验收标准。
/// 特点：取件码用"凭X到/取/领"句式、只有运单尾号、发件方与实际快递公司不一致。
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
            "【圆通快递】凭54-1-6707到成都双流区保利创智锦城店取运单尾号6707包裹")
        XCTAssertEqual(info.carrier, "圆通速递")
        XCTAssertEqual(info.pickupCode, "54-1-6707")
        XCTAssertEqual(info.trackingTail, "6707")
        XCTAssertEqual(info.station, "成都双流区保利创智锦城店")
        XCTAssertEqual(info.status, .awaitingPickup)
        XCTAssertGreaterThanOrEqual(confidence, 0.8)
    }

    func testShentongPingCodeStyle() throws {
        let (info, _) = try parsePackage(
            "【申通快递】凭1-2-6865到成都双流区保利创智锦城店取运单尾号6865包裹")
        XCTAssertEqual(info.carrier, "申通快递")
        XCTAssertEqual(info.pickupCode, "1-2-6865")
        XCTAssertEqual(info.trackingTail, "6865")
    }

    func testMerchantSFTrackingNumber() throws {
        let (info, _) = try parsePackage(
            "尊敬的客户【kiwi】：快递需要在对应的平台付费才能打印发货单【您的快递单号:SF5115322590293】")
        XCTAssertEqual(info.carrier, "顺丰速运")
        XCTAssertEqual(info.trackingNumber, "SF5115322590293")
        XCTAssertEqual(info.status, .inTransit)
    }

    func testJDSenderButZTOCarrier() throws {
        // 发件方是京东（商家），实际承运是中通
        let (info, _) = try parsePackage("【京东】74100503977397中通快递")
        XCTAssertEqual(info.carrier, "中通快递")
        XCTAssertEqual(info.trackingNumber, "74100503977397")
    }

    func testYundaStoreSenderButShentongCarrier() throws {
        // 发件方是韵达超市（代收点），实际快递是申通
        let (info, _) = try parsePackage(
            "【韵达超市】您的申通快递包裹已到福安路君悦湾B区4号门车库旁右边第四个门市韵达快递，请凭8-1-2513取件")
        XCTAssertEqual(info.carrier, "申通快递")
        XCTAssertEqual(info.pickupCode, "8-1-2513")
        XCTAssertEqual(info.station, "福安路君悦湾B区4号门车库旁右边第四个门市")
        XCTAssertEqual(info.status, .awaitingPickup)
    }

    func testYixiaogePlainNumericCode() throws {
        let (info, _) = try parsePackage(
            "【驿小哥】您的快递顺丰，已到君悦湾B区四号车库旁10-1-15号顺丰门市，凭16009免费取，如有疑问可到店咨询，谢谢")
        XCTAssertEqual(info.carrier, "顺丰速运")
        XCTAssertEqual(info.pickupCode, "16009")
        XCTAssertEqual(info.station, "君悦湾B区四号车库旁10-1-15号顺丰门市")
        XCTAssertEqual(info.status, .awaitingPickup)
    }

    func testJDTailNumberAtSFStore() throws {
        let (info, _) = try parsePackage(
            "【京东快递】快递尾号58371已放在顺丰门市，快递员电话13599063376，查看签收照片或反馈异常 3.cn/2-EwX1Ty")
        XCTAssertEqual(info.carrier, "京东物流")
        XCTAssertEqual(info.trackingTail, "58371")
        XCTAssertEqual(info.station, "顺丰门市")
        XCTAssertNil(info.trackingNumber, "快递员手机号不能被误认成单号")
        XCTAssertEqual(info.status, .awaitingPickup)
    }

    func testZTOConvenienceStore() throws {
        let (info, _) = try parsePackage(
            "【中通快递】包裹已到高新路86号领先心城西门旁沃惠生活便利店，请凭16-3-4313领取")
        XCTAssertEqual(info.carrier, "中通快递")
        XCTAssertEqual(info.pickupCode, "16-3-4313")
        XCTAssertEqual(info.station, "高新路86号领先心城西门旁沃惠生活便利店")
        XCTAssertEqual(info.status, .awaitingPickup, "「请…领取」不能被误判为已领取")
    }

    func testYundaWithAddressSuffix() throws {
        let (info, _) = try parsePackage(
            "【韵达快递】凭27-3-3536到成都双流区保利创智锦城店取货，地址：德华路13号(公寓2栋背后商铺-九雀筒24小时无人自助超市)")
        XCTAssertEqual(info.carrier, "韵达快递")
        XCTAssertEqual(info.pickupCode, "27-3-3536")
        XCTAssertEqual(info.station, "成都双流区保利创智锦城店")
    }

    func testHumanTypedMessageFallsToLLM() throws {
        // 快递员手打的短信，没有结构化字段，应低置信度落给 LLM 兜底
        let (info, confidence) = try parsePackage(
            "你好京东快递，君悦湾B区快递到了，打你电话没接，放4号门顺丰门市的，记得拿")
        XCTAssertNil(info.pickupCode)
        XCTAssertLessThan(confidence, 0.8)
    }
}
