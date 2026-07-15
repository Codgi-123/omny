import SwiftUI
import SwiftData
import OmnyCore

// 让取件勾选圈只跟「大号取件码数字」的垂直中心对齐（而非含上方小标签的整块居中）
extension VerticalAlignment {
    private enum CodeCenter: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[VerticalAlignment.center] }
    }
    static let codeCenter = VerticalAlignment(CodeCenter.self)
}

// MARK: - 快递卡（取件码大字 + 复制 + 标记已取）
// 卡片本体不带背景——作为 List 单元格时由分组表提供表面；作首页轮播时外层加 .cardStyle()。

struct PackageCard: View {
    @Bindable var item: InboxItem
    var showsContextMenu = true          // 首页传 false 关闭长按菜单
    @Environment(\.modelContext) private var context
    // 复制取件码的成功反馈：共享状态机，见 Views/Components/Feedback.swift
    @State private var copyFeedback = CopyFeedback()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 头部：图标与标题垂直居中；右侧状态标签
            HStack(spacing: 12) {
                CarrierIcon(carrier: item.carrier, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.carrier ?? "快递")
                        .font(.headline)
                    if let station = item.station {
                        Text(station)
                            .font(.subheadline)
                            .foregroundStyle(Theme.sub)
                            .lineLimit(1)
                    }
                }
                Spacer()
                statusTag
                    .contentTransition(.opacity)
                    .animation(.snappy, value: item.packageStatus)
            }

            // 主体：取件码（点按复制）/ 单号，右侧取件勾选圈（圈与数字中心对齐）
            HStack(alignment: .codeCenter, spacing: 12) {
                if let code = item.pickupCode {
                    Button {
                        copyFeedback.copy(code)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(copyFeedback.copied ? "已复制取件码" : "取件码 · 点按复制")
                                    .font(.caption)
                                    .foregroundStyle(copyFeedback.copied ? Theme.green : Theme.sub)
                                    .contentTransition(.opacity)
                                // 细线条复制图标（tab 栏同风格），复制成功切成对勾
                                CopyGlyph(copied: copyFeedback.copied, size: 12)
                            }
                            Text(code)
                                // SF Rounded：原生圆润数字，比默认更柔和；用文本样式随 Dynamic Type 缩放
                                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(Theme.express)
                                .alignmentGuide(.codeCenter) { $0[VerticalAlignment.center] }
                        }
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("复制取件码")
                    .sensoryFeedback(.impact(weight: .light), trigger: copyFeedback.copied) { _, now in now }
                } else if let number = item.trackingNumber ?? item.trackingTail {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("单号")
                            .font(.caption)
                            .foregroundStyle(Theme.sub)
                        Text(number)
                            .font(.system(.title3, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                            .alignmentGuide(.codeCenter) { $0[VerticalAlignment.center] }
                    }
                }
                Spacer(minLength: 8)
                pickupButton
                    .alignmentGuide(.codeCenter) { $0[VerticalAlignment.center] }
            }

            // 底部：收件时间
            Text(receivedText)
                .font(.caption)
                .foregroundStyle(Theme.sub)
        }
        .contentShape(Rectangle())
        .contextMenuIf(showsContextMenu) {
            if let code = item.pickupCode {
                Button {
                    UIPasteboard.general.string = code
                } label: {
                    Label("复制取件码", systemImage: "doc.on.doc")
                }
            }
            Button(role: .destructive) {
                context.delete(item)
                try? context.save()
            } label: { Label("删除", systemImage: "trash") }
        }
    }

    // 收件时间：不显示年，带星期几，固定按 UTC+8 展示（例：7月10日周五 23:44）
    // locale 锁死简体中文——否则跟随系统语言，英文机上会显示成 "Fri, Jul 10 at ..."
    private var receivedText: String {
        item.createdAt.formatted(
            Date.FormatStyle(locale: Locale(identifier: "zh_CN"),
                             timeZone: TimeZone(secondsFromGMT: 8 * 3600)!)
                .month().day().weekday(.abbreviated).hour().minute()
        )
    }

    // 取件勾选圈：外观见 PickupCheckButton（标准卡图标 24pt）
    private var pickupButton: some View {
        PickupCheckButton(item: item)
    }

    private var statusTag: some View {
        switch item.packageStatus {
        // 只有"待取"是需要用户行动的状态 → 用强调色；其余是信息态 → 中性灰
        case .awaitingPickup: StatusTag(text: "待取", color: Theme.express)
        case .outForDelivery: StatusTag(text: "派送中", color: Theme.sub)
        case .inTransit: StatusTag(text: "在途", color: Theme.sub)
        case .pickedUp: StatusTag(text: "已签收", color: Theme.sub)
        }
    }
}

// MARK: - 快递卡·紧凑版（首页轮播用：一行装下核心信息，密度更高）

struct PackageCardCompact: View {
    @Bindable var item: InboxItem
    @Environment(\.modelContext) private var context
    // 复制取件码的成功反馈：共享状态机，见 Views/Components/Feedback.swift
    @State private var copyFeedback = CopyFeedback()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 顶排：包裹图标 + 承运商名 + 取件圈，垂直居中对齐
            HStack(alignment: .center, spacing: 8) {
                CarrierIcon(carrier: item.carrier, size: 36)
                Text(item.carrier ?? "快递")
                    .font(.system(size: 22, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                pickupButton
            }
            VStack(alignment: .leading, spacing: 3) {
                codeLine
                if let station = item.station {
                    Text(station)
                        .font(.caption2)
                        .foregroundStyle(Theme.sub)
                        .lineLimit(1)
                }
                Text(timeText)
                    .font(.caption2)
                    .foregroundStyle(Theme.sub)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder private var codeLine: some View {
        if let code = item.pickupCode {
            Button {
                copyFeedback.copy(code)
            } label: {
                HStack(spacing: 5) {
                    Text(code)
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.express)
                        .lineLimit(1)
                    // 细线条复制图标（tab 栏同风格），复制成功切成对勾
                    CopyGlyph(copied: copyFeedback.copied, size: 13)
                }
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("复制取件码")
            .sensoryFeedback(.impact(weight: .light), trigger: copyFeedback.copied) { _, now in now }
        } else if let number = item.trackingNumber ?? item.trackingTail {
            Text("单号 \(number)")
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(Theme.text)
                .lineLimit(1)
        }
    }

    // 收件时间：不显示年，按 UTC+8（例：7月10日 23:44）
    private var timeText: String {
        item.createdAt.formatted(
            Date.FormatStyle(locale: Locale(identifier: "zh_CN"),
                             timeZone: TimeZone(secondsFromGMT: 8 * 3600)!)
                .month().day().hour().minute()
        )
    }

    // 紧凑卡的取件圈：图标 22pt（比标准卡 24pt 略小，密度对齐紧凑排版，刻意差异）
    private var pickupButton: some View {
        PickupCheckButton(item: item, symbolSize: 22)
    }
}

// MARK: - 取件勾选圈（提醒事项式，标准卡/紧凑卡共用）

/// 取件勾选圈：空心圈 → 绿色实心对勾 + 成功触感。直接操作、就地切换，
/// 横向轮播/竖向列表都适用，不与横滑冲突。双向状态推进（待取 ⇄ 已签收）的
/// 业务语义在这里承载，外观与 44pt 命中区交给 CheckToggleButton。
struct PickupCheckButton: View {
    @Bindable var item: InboxItem
    var symbolSize: CGFloat = 24
    @Environment(\.modelContext) private var context

    var body: some View {
        let done = item.packageStatus == .pickedUp
        CheckToggleButton(symbol: done ? "checkmark.circle.fill" : "circle",
                          tint: done ? Theme.green : Theme.express.opacity(0.85),
                          symbolSize: symbolSize,
                          accessibilityLabel: done ? "撤销取件" : "确认取件") {
            withAnimation(.snappy) {
                item.packageStatus = done ? .awaitingPickup : .pickedUp
            }
            try? context.save()
        }
        .sensoryFeedback(trigger: item.packageStatus) { _, new in
            new == .pickedUp ? .success : nil
        }
    }
}

// MARK: - 复制图标（细线条 tab 栏同风格）

/// 快递卡「复制取件码」用的细线条图标：常态是叠放两张纸（Assets 的 IconCopy），
/// 复制成功后柔和交叉淡入淡出切成对勾。整套走白/灰细线，和底部 tab 图标同一风格。
struct CopyGlyph: View {
    let copied: Bool
    var size: CGFloat = 13

    var body: some View {
        ZStack {
            Image("IconCopy")
                .resizable()
                .renderingMode(.template)
                .frame(width: size, height: size)
                .foregroundStyle(Theme.sub)
                .opacity(copied ? 0 : 1)
            Image(systemName: "checkmark")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(Theme.green)
                .opacity(copied ? 1 : 0)
        }
        .animation(.snappy, value: copied)
    }
}

// MARK: - 行程图标块（机票 / 火车 / 酒店）

/// 行程图标块：全彩拟物 SVG（侧视客机 / 高铁头车 / 木床），风格对齐快递的 CarrierIcon 纸箱
/// （柔和投影 + 低透明度描边 + 靛蓝分类色点缀）。不再用「分类色底 + 白色形状」的 chip 样式。
/// 资源见 Assets 的 TripFlight / TripTrain / TripHotel（original 渲染、保留矢量）。
struct TripIconChip: View {
    let kindRaw: String?
    var size: CGFloat = 34

    private var assetName: String {
        switch kindRaw {
        case "flight": "TripFlight"
        case "hotel": "TripHotel"
        default: "TripTrain"
        }
    }

    private var label: String {
        switch kindRaw {
        case "flight": "航班"
        case "hotel": "住宿"
        default: "火车"
        }
    }

    var body: some View {
        Image(assetName)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityLabel(label)
    }
}

// MARK: - 行程卡（时间路线 + 倒计时）

struct TripCard: View {
    let item: InboxItem
    @Environment(\.modelContext) private var context
    /// 航班动态缓存（10 分钟 TTL，页面负责触发刷新）；命中时机票卡显示三字码/航站楼/登机口等
    @ObservedObject private var flightStore = FlightDynamicsStore.shared

    private var isHotel: Bool { item.tripKindRaw == "hotel" }
    private var isFlight: Bool { item.tripKindRaw == "flight" }

    /// 标题：机票是「航司名 + 航班号」（航司由航班号前缀离线映射）；火车用车次号；
    /// 酒店无班次号，用酒店/民宿名（departPlace，见 TripInfo.Kind.hotel 的字段映射）
    private var title: String {
        if isHotel { return item.departPlace ?? "住宿" }
        if let number = item.tripNumber, !number.isEmpty {
            if isFlight, let airline = AirlineNames.name(forFlightNo: number) {
                return "\(airline) \(number)"
            }
            return number
        }
        return "行程"
    }

    /// 日期 + 星期（融进时间路线中间，作为出发到达之间的强化标签）
    private var dateWeekday: String? {
        item.departAt?.formatted(
            .dateTime.locale(Locale(identifier: "zh_CN")).month().day().weekday(.abbreviated))
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                TripIconChip(kindRaw: item.tripKindRaw, size: 44)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.headline)
                    // 酒店时 seat 存的是房型；机票座位挪去了地面信息行
                    if let seat = item.seat, !isFlight {
                        Text(seat)
                            .font(.caption)
                            .foregroundStyle(Theme.sub)
                    }
                }
                Spacer()
                if isFlight {
                    // 机票路线正中让位给时长/状态，日期星期上移到卡片右上
                    VStack(alignment: .trailing, spacing: 3) {
                        statusTag
                        if let dateWeekday {
                            Text(dateWeekday)
                                .font(.caption2)
                                .foregroundStyle(Theme.sub)
                        }
                    }
                } else {
                    statusTag
                }
            }
            if isHotel {
                hotelRoute
            } else if isFlight {
                flightRoute
                flightGroundRow
            } else {
                transitRoute
            }
        }
    }

    /// 车/机：出发前倒计时，出发后已结束；酒店：入住前倒计时 → 入住中 → 离店后已结束
    @ViewBuilder private var statusTag: some View {
        if isHotel {
            if let checkIn = item.departAt, checkIn > .now {
                StatusTag(text: countdown(to: checkIn) + "后", color: Theme.trip)
            } else if let checkOut = item.arriveAt, checkOut > .now {
                StatusTag(text: "入住中", color: Theme.trip)
            } else if item.departAt != nil || item.arriveAt != nil {
                StatusTag(text: "已结束", color: Theme.sub)
            }
        } else if let depart = item.departAt {
            if depart > .now {
                StatusTag(text: countdown(to: depart) + "后", color: Theme.trip)
            } else {
                StatusTag(text: "已结束", color: Theme.sub)
            }
        }
    }

    // MARK: 酒店路线行（入住 —（N晚 + 箭头）— 离店，复用车/机路线的三栏骨架）

    /// 入住/离店跨天，两侧主文字放日期（车/机放时分）；正中放晚数（车/机放日期星期）
    private var nights: Int? {
        guard let checkIn = item.departAt, let checkOut = item.arriveAt else { return nil }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: checkIn),
                                      to: cal.startOfDay(for: checkOut)).day ?? 0
        return days > 0 ? days : nil
    }

    private func hotelDate(_ date: Date?) -> String {
        date?.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day()) ?? "--"
    }

    /// 时刻标签：解析常只有日期没有时刻（补年后时刻为 0:00），非零时刻才展示（如「14:00 入住」）
    private func hotelTimeLabel(_ date: Date?, _ verb: String) -> String {
        guard let date else { return verb }
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        guard (c.hour ?? 0) != 0 || (c.minute ?? 0) != 0 else { return verb }
        return date.formatted(date: .omitted, time: .shortened) + " " + verb
    }

    private var hotelRoute: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(hotelDate(item.departAt))
                    .font(.title2)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                Text(hotelTimeLabel(item.departAt, "入住"))
                    .font(.footnote)
                    .foregroundStyle(Theme.sub)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 3) {
                if let nights {
                    Text("\(nights)晚")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.trip)
                        .lineLimit(1)
                }
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(Theme.sub)
            }
            .fixedSize()

            VStack(alignment: .trailing, spacing: 4) {
                Text(hotelDate(item.arriveAt))
                    .font(.title2)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                Text(hotelTimeLabel(item.arriveAt, "离店"))
                    .font(.footnote)
                    .foregroundStyle(Theme.sub)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    // MARK: 车/机路线行

    // 出发 —（日期·星期 + 箭头）— 到达：日期星期升到路线正中，与出发/到达时间同一视觉层，不再是底部孤立小灰字
    private var transitRoute: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.departAt?.formatted(date: .omitted, time: .shortened) ?? "--:--")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                Text(item.departPlace ?? "出发")
                    .font(.footnote)
                    .foregroundStyle(Theme.sub)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 3) {
                if let dateWeekday {
                    Text(dateWeekday)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.trip)
                        .lineLimit(1)
                }
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(Theme.sub)
            }
            .fixedSize()

            VStack(alignment: .trailing, spacing: 4) {
                Text(item.arriveAt?.formatted(date: .omitted, time: .shortened) ?? "--:--")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                Text(item.arrivePlace ?? "到达")
                    .font(.footnote)
                    .foregroundStyle(Theme.sub)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    // MARK: 机票路线行（登机牌样式）

    private var flightDynamics: FlightDynamics? { flightStore.dynamics(for: item) }

    /// 时刻优先级：动态预计时间（延误时与计划不同）→ 动态计划时间 → 短信解析时间
    private var flightRoute: some View {
        let dyn = flightDynamics
        let dep = dyn?.depEstimateTime ?? dyn?.depPlanTime ?? item.departAt
        let arr = dyn?.arrEstimateTime ?? dyn?.arrPlanTime ?? item.arriveAt
        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(dep?.formatted(date: .omitted, time: .shortened) ?? "--:--")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                if let code = dyn?.depCode {
                    Text(code)
                        .font(.subheadline.weight(.semibold))
                }
                if let place = Self.placeLine(item.departPlace, terminal: dyn?.depTerminal) {
                    Text(place)
                        .font(.caption)
                        .foregroundStyle(Theme.sub)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 4) {
                if let duration = Self.durationText(dep, arr) {
                    Text(duration)
                        .font(.caption2)
                        .foregroundStyle(Theme.sub)
                }
                HStack(spacing: 4) {
                    FlightDashLine()
                    Image(systemName: "airplane")
                        .font(.caption2)
                        .foregroundStyle(Theme.trip)
                    FlightDashLine()
                }
                if let state = dyn?.state {
                    Text(state)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Self.stateColor(state))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(arr?.formatted(date: .omitted, time: .shortened) ?? "--:--")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                if let code = dyn?.arrCode {
                    Text(code)
                        .font(.subheadline.weight(.semibold))
                }
                if let place = Self.placeLine(item.arrivePlace, terminal: dyn?.arrTerminal) {
                    Text(place)
                        .font(.caption)
                        .foregroundStyle(Theme.sub)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// 登机口 / 座位 / 行李转盘：有任一数据才显示整行，无值格子占位「—」
    @ViewBuilder private var flightGroundRow: some View {
        let dyn = flightDynamics
        if dyn != nil || item.seat != nil {
            HStack(spacing: 8) {
                flightGroundCell("登机口", dyn?.gate)
                flightGroundCell("座位", item.seat)
                flightGroundCell("行李转盘", dyn?.luggage)
            }
        }
    }

    private func flightGroundCell(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.sub)
            Text((value?.isEmpty == false ? value : nil) ?? "—")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 机场名与航站楼拼接（短信地名 + 动态航站楼）；地名里已含航站楼时不重复
    static func placeLine(_ place: String?, terminal: String?) -> String? {
        switch (place, terminal) {
        case let (place?, terminal?):
            return place.localizedCaseInsensitiveContains(terminal) ? place : "\(place) \(terminal)"
        case let (place?, nil): return place
        case let (nil, terminal?): return terminal
        default: return nil
        }
    }

    /// 飞行时长「2小时45分」；到达早于出发（数据异常/缺失）不显示
    static func durationText(_ dep: Date?, _ arr: Date?) -> String? {
        guard let dep, let arr, arr > dep else { return nil }
        let minutes = Int(arr.timeIntervalSince(dep) / 60)
        if minutes < 60 { return "\(minutes)分钟" }
        let remainder = minutes % 60
        return remainder == 0 ? "\(minutes / 60)小时" : "\(minutes / 60)小时\(remainder)分"
    }

    /// 航班状态着色：延误/取消警示红，起飞/到达/降落完成绿，其余（计划等）用行程色
    static func stateColor(_ state: String) -> Color {
        if state.contains("延误") || state.contains("取消") { return .red }
        if state.contains("起飞") || state.contains("到达") || state.contains("降落") {
            return Theme.green
        }
        return Theme.trip
    }

    private func countdown(to date: Date) -> String {
        let seconds = date.timeIntervalSinceNow
        if seconds < 3600 { return "\(max(1, Int(seconds / 60))) 分钟" }
        if seconds < 48 * 3600 { return "\(Int(seconds / 3600)) 小时" }
        return "\(Int(seconds / 86400)) 天"
    }
}

/// 机票路线中间的虚线（两段夹一架小飞机）
private struct FlightDashLine: View {
    var body: some View {
        LineShape()
            .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .foregroundStyle(Theme.line)
            .frame(height: 1)
    }

    private struct LineShape: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: 0, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.width, y: rect.midY))
            return path
        }
    }
}

// MARK: - 待办行（勾选 + 同步状态）

/// 让「方框 / 标题 / 旗帜」三者的垂直中心对齐到同一条线（各自在多行列里也能对齐）。
private extension VerticalAlignment {
    enum CheckTitle: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[VerticalAlignment.center] }
    }
    static let checkTitle = VerticalAlignment(CheckTitle.self)
}

struct TodoRow: View {
    @Bindable var item: InboxItem
    var showsContextMenu = true          // 首页传 false 关闭长按菜单
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var dida: DidaService
    @State private var editing = false

    private var isLocal: Bool { item.canEditLocally }

    /// 未勾选圆圈的颜色：有优先级时用优先级色着色（对齐滴答），否则中性灰
    private var uncheckedTint: Color {
        item.todoPriority == 0 ? Theme.sub : TodoPriority(raw: item.todoPriority).color
    }

    var body: some View {
        HStack(alignment: .checkTitle, spacing: 8) {
            // 视觉 36×26（滴答式小方框），命中区由 CheckToggleButton 保底外扩到 44pt
            CheckToggleButton(symbol: checkSymbol, tint: checkTint, symbolSize: 18,
                              visualSize: CGSize(width: 36, height: 26),
                              accessibilityLabel: checkLabel, action: toggleCheck)
                .sensoryFeedback(trigger: item.todoCompleted) { _, done in
                    done ? .success : nil
                }
                // 方框中心作为对齐基准
                .alignmentGuide(.checkTitle) { $0[VerticalAlignment.center] }

            VStack(alignment: .leading, spacing: 3) {
                // 标题 + 紧跟其后的来源 tag（本地/滴答）；tag 是小字号胶囊，按基线对齐会视觉偏低，改用居中
                HStack(alignment: .center, spacing: 6) {
                    Text(item.todoTitle ?? item.rawText)
                        .font(.body)
                        // 只有「放弃」才划线；「已完成」仅变灰不划线
                        .strikethrough(item.todoAbandoned)
                        .foregroundStyle(item.todoCompleted || item.todoAbandoned ? Theme.sub : Theme.text)
                    sourceTag
                }
                // 标题行中心对齐到方框中心
                .alignmentGuide(.checkTitle) { $0[VerticalAlignment.center] }
                if let note = item.todoNote?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(Theme.sub)
                        .lineLimit(2)
                }
                // 截止时间移到标题/描述下方；有具体时分才带时分，纯日期只显示日期
                if let due = item.todoDue {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.caption2)
                        Text(dueLabel(due))
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .foregroundStyle(dueColor(due))
                }
            }

            Spacer(minLength: 4)
        }
        // 本地待办：点按编辑、左滑删除/编辑；滴答待办只读（仅完成勾选可用）
        .contentShape(Rectangle())
        .onTapGesture { if isLocal { editing = true } }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if isLocal {
                // 删除：红色底（role .destructive）；「编辑」改为「放弃」（灰系，与删除的红区分）
                Button(role: .destructive) { delete() } label: { Label("删除", systemImage: "trash") }
                if item.todoAbandoned {
                    Button { restore() } label: { Label("恢复", systemImage: "arrow.uturn.backward") }
                        .tint(Theme.accent)
                } else {
                    Button { abandon() } label: { Label("放弃", systemImage: "xmark.bin") }
                        .tint(Color(.systemGray))
                }
            }
        }
        .contextMenuIf(showsContextMenu) {
            if isLocal {
                Button { editing = true } label: { Label("编辑", systemImage: "pencil") }
                if item.todoAbandoned {
                    Button { restore() } label: { Label("恢复", systemImage: "arrow.uturn.backward") }
                } else {
                    Button { abandon() } label: { Label("放弃", systemImage: "xmark.bin") }
                }
                Button(role: .destructive) { delete() } label: { Label("删除", systemImage: "trash") }
            }
        }
        .sheet(isPresented: $editing) { TodoEditSheet(item: item, onDelete: delete) }
    }

    private func delete() {
        // 本地待办软删除进回收站，7 天内可恢复（与快递/收藏一致）
        withAnimation(.snappy) { Trash.softDelete(item, context: context) }
    }

    /// 勾选：放弃态点按撤销放弃；否则切换完成（滴答待办需标脏回写）。
    private func toggleCheck() {
        if item.todoAbandoned {
            withAnimation(.snappy) { item.todoAbandoned = false }
            try? context.save()
            return
        }
        withAnimation(.snappy) { item.todoCompleted.toggle() }
        // 滴答待办：完成/取消完成要标脏并回写滴答；本地待办纯本地，只存不同步
        if item.isDidaSynced { item.needsPush = true }
        try? context.save()
        if item.isDidaSynced { Task { await dida.syncNow(context: context) } }
    }

    /// 放弃：纯本地展示状态。不改完成态、不标脏 → 不会被当成完成推送滴答；远端拉取也不复活（仅前台过滤展示）。
    private func abandon() {
        withAnimation(.snappy) { item.todoAbandoned = true }
        try? context.save()
    }

    /// 撤销放弃，回到未完成。
    private func restore() {
        withAnimation(.snappy) { item.todoAbandoned = false }
        try? context.save()
    }

    private var checkSymbol: String {
        if item.todoAbandoned { return "xmark.square.fill" }   // 放弃：叉叉方框
        return item.todoCompleted ? "checkmark.square.fill" : "square"
    }
    private var checkTint: Color {
        if item.todoAbandoned { return Theme.sub }
        return item.todoCompleted ? Theme.green : uncheckedTint
    }
    private var checkLabel: String {
        if item.todoAbandoned { return "撤销放弃" }
        return item.todoCompleted ? "标记为未完成" : "标记为完成"
    }

    /// 来源标签：本地待办「本地」、滴答待办「滴答」。
    private var sourceTag: some View {
        let dida = item.isDidaSynced
        return Text(dida ? "滴答" : "本地")
            .font(.caption2.weight(.medium))
            .foregroundStyle(dida ? Theme.accent : Theme.sub)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((dida ? Theme.accent : Theme.sub).opacity(0.12), in: Capsule())
    }

    private func dueLabel(_ date: Date) -> String {
        let cal = Calendar.current
        // 有具体时分才显示时分；纯日期型截止只显示日期
        let hasTime = cal.component(.hour, from: date) != 0 || cal.component(.minute, from: date) != 0
        let zh = Locale(identifier: "zh_CN")
        if cal.isDateInToday(date) {
            return hasTime ? "今天 " + date.formatted(date: .omitted, time: .shortened) : "今天"
        }
        return hasTime ? date.formatted(.dateTime.locale(zh).month().day().hour().minute())
                       : date.formatted(.dateTime.locale(zh).month().day())
    }

    /// 截止色：已过期红、今天蓝、其余灰。
    private func dueColor(_ date: Date) -> Color {
        let cal = Calendar.current
        if cal.startOfDay(for: date) < cal.startOfDay(for: Date()) { return Theme.red }
        if cal.isDateInToday(date) { return Theme.accent }
        return Theme.sub
    }
}

// MARK: - 本地待办编辑弹窗（仿参考图的底部详情卡）。仅用于本地来源待办。

struct TodoEditSheet: View {
    @Bindable var item: InboxItem
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var title: String
    @State private var note: String
    @State private var due: Date?
    @State private var priority: Int
    @State private var completed: Bool
    @State private var showDate = false
    @State private var showPriority = false
    @State private var confirmDelete = false
    @FocusState private var focus: Field?

    private enum Field { case title, note }

    init(item: InboxItem, onDelete: @escaping () -> Void) {
        self.item = item
        self.onDelete = onDelete
        _title = State(initialValue: item.todoTitle ?? item.rawText)
        _note = State(initialValue: item.todoNote ?? "")
        _due = State(initialValue: item.todoDue)
        _priority = State(initialValue: item.todoPriority)
        _completed = State(initialValue: item.todoCompleted)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            topRow
            dateRow

            TextField("准备做什么？", text: $title, axis: .vertical)
                .font(.title3.weight(.semibold))
                .lineLimit(1...4)
                .focused($focus, equals: .title)

            // 描述：输入框 + 下方整片空白都可点，点任意处进入编辑
            VStack(alignment: .leading, spacing: 0) {
                TextField("描述", text: $note, axis: .vertical)
                    .font(.subheadline)
                    .foregroundStyle(Theme.sub)
                    .focused($focus, equals: .note)
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { focus = .note }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(20)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showDate) { DueDateSheet(due: $due) }
        .sheet(isPresented: $showPriority) { PrioritySheet(priority: $priority) }
        .alert("删除这条待办？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) { onDelete(); dismiss() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会移到回收站，7 天内可在「回收站」恢复。")
        }
        .onDisappear(perform: commit)
    }

    // MARK: 顶部：来源标签 + 优先级 + 删除

    private var topRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "tray.full")
                Text(item.isDidaSynced ? "滴答清单" : "本地待办")
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Theme.sub)

            Spacer()

            Button { focus = nil; showPriority = true } label: {
                Image(systemName: priority == 0 ? "flag" : "flag.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(priority == 0 ? Theme.accent : TodoPriority(raw: priority).color)
                    .frame(width: 40, height: 40)
                    .background(Theme.fill, in: Circle())
            }
            .buttonStyle(PressableStyle(scale: 0.9))

            Button { focus = nil; confirmDelete = true } label: {
                Image(systemName: "trash")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.red)
                    .frame(width: 40, height: 40)
                    .background(Theme.red.opacity(0.12), in: Circle())
            }
            .buttonStyle(PressableStyle(scale: 0.9))
        }
    }

    // MARK: 完成勾选 + 日期

    private var dateRow: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.snappy) { completed.toggle() }
            } label: {
                Image(systemName: completed ? "checkmark.square.fill" : "square")
                    .font(.system(size: 18))
                    .foregroundStyle(completed ? Theme.green
                                     : (priority == 0 ? Theme.sub : TodoPriority(raw: priority).color))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PressableStyle(scale: 0.9))

            Button { focus = nil; showDate = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                    Text(due.map(dueText) ?? "日期&提醒")
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(due == nil ? Theme.sub : Theme.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background((due == nil ? Theme.sub : Theme.accent).opacity(0.12), in: Capsule())
            }
            .buttonStyle(PressableStyle())

            Spacer()
        }
    }

    private func dueText(_ d: Date) -> String {
        let cal = Calendar.current
        let time = (cal.component(.hour, from: d) != 0 || cal.component(.minute, from: d) != 0)
        if cal.isDateInToday(d) {
            return time ? "今天 " + d.formatted(date: .omitted, time: .shortened) : "今天"
        }
        let zh = Locale(identifier: "zh_CN")
        // 非今天：带上星期（四.5）
        return time ? d.formatted(.dateTime.locale(zh).month().day().weekday().hour().minute())
                    : d.formatted(.dateTime.locale(zh).month().day().weekday())
    }

    /// 关闭时统一落库（标题为空回退到原文）。
    private func commit() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        item.todoTitle = trimmed.isEmpty ? item.rawText : trimmed
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        item.todoNote = n.isEmpty ? nil : n
        item.todoDue = due
        item.todoPriority = priority
        item.todoCompleted = completed
        try? context.save()
    }
}
