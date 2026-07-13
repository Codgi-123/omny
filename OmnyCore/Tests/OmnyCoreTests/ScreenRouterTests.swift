import XCTest
@testable import OmnyCore

/// ScreenRouter（第一层规则路由）：用例来自真实截图 OCR 语料（脱敏），
/// 与 scripts/screen_router_proto.swift 的校准结果保持一致。
/// 新增指纹/锚点/词袋时，把对应真实截图的 OCR 文本脱敏后补进来。
final class ScreenRouterTests: XCTestCase {

    // MARK: - 记账

    /// 微信/支付宝支付成功页：指纹（支付成功）+ 独行金额 + 身份锚点 → 记账
    func testPaymentSuccessRoutesExpense() {
        let ocr = """
        18:08
        ×
        扫二维码付款-给某某
        -19.00
        当前状态
        支付方式
        转账单号
        支付成功
        零钱
        2025年11月1日16:06:42
        4800002944202511415521099625
        账单服务
        """
        XCTAssertEqual(ScreenRouter.route(ocr).category, .expense)
    }

    /// 微信红包/收款详情页：没有「支付成功」标题，靠「红包详情」指纹 + 交易单号词身份锚点
    func testRedPacketDetailRoutesExpense() {
        let ocr = """
        21:06
        当前状态
        红包详情
        收款时间
        交易单号
        商户单号
        微信红包-来自某某
        +5.00
        已存入零钱
        2025年11月1日 16:06:42
        """
        XCTAssertEqual(ScreenRouter.route(ocr).category, .expense)
    }

    // MARK: - 行程（含酒店）

    /// 12306 订票页：车次号锚点 + 票务词袋。价格标签（整数）不应给记账加分
    func test12306BookingRoutesTrip() {
        let ocr = """
        前一天
        05:13
        西安北
        圈北京丰台
        05月23日 周六
        四D965>
        退改说明
        08:43
        成都东
        二等
        动卧
        ¥440起
        无座
        ¥263
        1.一天内3次申请车票成功后取消订单，当日将不能在12306继续购票。
        2.如因运力原因导致列车调度调整时，当前车型可能会发生变动。
        """
        let decision = ScreenRouter.route(ocr)
        XCTAssertEqual(decision.category, .trip)
        XCTAssertEqual(decision.scores[.expense], 0, "整数价格标签不应触发金额锚点")
    }

    /// 民宿订单页：行首杂符号剥离后命中「分享房源」指纹 + 晚数/入住离店锚点
    func testHotelOrderRoutesTrip() {
        let ocr = """
        ～分享房源
        四 联系房东
        日10月4日周六-10月6日周一（2晚
        14:00后入住
        12:00前离店
        某某区整套房源
        """
        XCTAssertEqual(ScreenRouter.route(ocr).category, .trip)
    }

    /// 美团民宿订单页带真实支付信息：记账分数高但无「交易身份」信号（订单页的金额是
    /// 订单价格）→ 身份门槛压制，判单类行程
    func testHotelOrderWithPaymentInfoStillRoutesTrip() {
        let ocr = """
        ②已完成
        ¥200退押成功
        1～3工作日内到账＞
        在线支付
        ¥1870.34
        已优惠 ¥327.66
        ～分享房源
        四 联系房东
        日10月4日周六-10月6日周一（2晚
        14:00后入住
        12:00前离店
        某某区整套房源
        删除订单
        再次预订
        """
        let decision = ScreenRouter.route(ocr)
        XCTAssertEqual(decision.category, .trip)
        XCTAssertGreaterThanOrEqual(decision.scores[.expense] ?? 0, ScreenRouter.routeThreshold,
                                    "记账分数达标但被身份门槛压制，才能证明门槛生效")
    }

    // MARK: - 快递

    func testStationNoticeRoutesPackage() {
        let ocr = """
        09:41
        菜鸟驿站
        【菜鸟驿站】您的韵达快递已到站
        凭取件码
        8-3-9012
        到某某小区西门菜鸟驿站取包裹
        运单尾号6707
        无更多文本
        """
        XCTAssertEqual(ScreenRouter.route(ocr).category, .package)
    }

    // MARK: - 待办

    /// 备忘录截图：只有指纹（待办无锚点无词袋），单指纹即可路由
    func testMemoRoutesTodo() {
        let ocr = """
        备忘录
        今天
        口 买牛奶
        口 下午取衣服（干洗店）
        17:32
        """
        XCTAssertEqual(ScreenRouter.route(ocr).category, .todo)
    }

    // MARK: - 无信号 / 多类达标

    /// 聊天记录：无任何规则信号 → nil，交第二层 LLM 分类
    func testChatHasNoSignal() {
        let ocr = """
        产品群
        李雷
        明天上午十点前把周报发我
        韩梅梅
        好的，另外记得订周三去上海的会议室
        按住说话
        """
        let decision = ScreenRouter.route(ocr)
        XCTAssertNil(decision.category)
        XCTAssertEqual(decision.scores.values.reduce(0, +), 0)
    }

    /// 通知中心混排（快递+银行动账）：混合暂不做，两类都达标时取最高分（快递）。
    /// 银行通知里的「储蓄卡」给记账身份，证明记账是被分数比下去的，不是被门槛压掉的。
    func testNotificationCenterMultiStrongPicksTop() {
        let ocr = """
        09:41 7月13日 星期日
        通知中心
        菜鸟
        你的包裹已到某某驿站，凭54-1-6707到店取件
        招商银行
        您尾号1234的储蓄卡7月13日消费19.00元
        微信
        张三：晚上吃饭吗
        """
        let decision = ScreenRouter.route(ocr)
        XCTAssertEqual(decision.category, .package)
        XCTAssertGreaterThanOrEqual(decision.scores[.expense] ?? 0, ScreenRouter.routeThreshold,
                                    "记账应达标（有银行卡身份），输在分数而非门槛")
    }

    /// 正文长句里出现指纹词不算指纹（「独占一行」才是版式证据）：
    /// 聊天里提到"支付成功"不该把聊天判成记账
    func testFingerprintInsideSentenceDoesNotCount() {
        let ocr = """
        产品群
        李雷
        我刚才支付成功了，你看下到账没
        按住说话
        """
        let decision = ScreenRouter.route(ocr)
        XCTAssertNil(decision.category, "正文措辞只算词袋，不足以路由")
    }
}
