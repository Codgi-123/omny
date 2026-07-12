import SwiftUI
import UIKit

/// 原生分组表配色：中性系统色做表面（自动明暗 + 正确对比度），只保留陶土橙做品牌强调。
enum Theme {
    static let screen   = Color(.systemGroupedBackground)           // 分组表底
    static let card     = Color(.secondarySystemGroupedBackground)  // 分组单元格 / 轮播卡表面
    static let cardWarm = Color(.secondarySystemGroupedBackground)
    static let text     = Color(.label)
    static let sub      = Color(.secondaryLabel)
    static let line     = Color(.separator)

    /// 卡片内小控件的统一铺底（搜索框底 / tag·chip 底 / 输入框底 / 圆钮底）。
    /// 用半透明填充档 tertiarySystemFill：叠在白卡或灰底上都协调；全 App 只用这一档，不混用其它 systemFill/systemGray。
    static let fill     = Color(.tertiarySystemFill)

    /// 品牌强调色：iOS 系统蓝（Apple 最经典的默认强调色）。原陶土橙已弃用。
    static let accent = Color(.systemBlue)
    static let green  = Color(.systemGreen)
    static let slate  = Color(.systemIndigo)
    static let red    = Color(.systemRed)

    /// 分类签名色：每类内容一个颜色，成体系地用在图标/关键数据上，给原生分组表加回识别度
    static let express  = Color(.systemBlue)    // 快递 · 蓝
    static let trip     = Color(.systemIndigo)  // 行程 · 靛
    static let todo     = Color(.systemGreen)   // 待办 · 绿
    static let bookmark = Color(.systemPink)    // 收藏 · 粉

    /// 记账消费分类的签名色板：给各消费大类一组成体系的色。
    /// 与 IconChip 组合（渐变色底 + 白 SF Symbol），和快递卡同一套渲染。
    /// 命名按语义（餐饮/交通…），未命中的分类由 ExpenseCategoryAppearance 按名 hash 从这里取一个兜底。
    enum ExpenseColor {
        static let food     = Color(.systemOrange)  // 餐饮 · 橙
        static let trans    = Color(.systemBlue)    // 交通 · 蓝
        static let shopping = Color(.systemPurple)  // 购物 · 紫
        static let home     = Color(.systemIndigo)  // 居家 · 靛
        static let fun      = Color(.systemPink)    // 娱乐 · 粉
        static let medical  = Color(.systemRed)     // 医疗 · 红
        static let income   = Color(.systemGreen)   // 收入 · 绿
        static let other    = Color(.systemTeal)    // 其他 · 青
        /// 兜底取色用的有序色板（未命中分类按名 hash 稳定落到其中一个）
        static let palette: [Color] = [food, trans, shopping, home, fun, medical, income, other]
    }

    /// 统一的间距刻度（4/8pt 栅格）
    enum Space {
        static let page: CGFloat = 16
        static let gap: CGFloat = 12
        static let cardPad: CGFloat = 16
    }
}

// MARK: 通用组件

/// 通用按压反馈：按下即缩，`.snappy` 快速回弹。替代 `.buttonStyle(.plain)`
/// —— `.plain` 会连系统高亮一起去掉，导致可点元素按下去毫无回应。
/// 勾选圈这类小目标可传更明显的 scale（如 0.9）。
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.97
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.snappy(duration: 0.14), value: configuration.isPressed)
    }
}

/// 卡片表面：中性单元格底 + 柔和阴影托出层次（App Store 卡片式的"浮起"质感，非旧的描边+阴影堆叠）。
struct CardBackground: ViewModifier {
    var warm = false
    var pad: CGFloat = Theme.Space.cardPad
    func body(content: Content) -> some View {
        content
            .padding(pad)
            .background(Theme.card, in: .rect(cornerRadius: 12))
            // 收紧阴影，避免晕影渗到卡片外的边距、看起来像背景色不均
            .shadow(color: .black.opacity(0.05), radius: 5, y: 2)
    }
}

/// 自定义大标题头部：左侧大号粗体标题 + 右侧操作按钮，同一行（App Store 首页式）。
/// 用它替代系统导航标题，让标题和右上角按钮真正同高。
struct ScreenHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center) {
            Text(title)
                .font(.largeTitle)
                .fontWeight(.bold)
            Spacer()
            trailing()
        }
        .padding(.horizontal, Theme.Space.page)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }
}

extension View {
    func cardStyle(warm: Bool = false, pad: CGFloat = Theme.Space.cardPad) -> some View {
        modifier(CardBackground(warm: warm, pad: pad))
    }

    /// 横向轮播作为 List row：整宽、清背景、无分隔线
    func carouselRow() -> some View {
        self
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    /// 独立富卡片作为 plain List 行：加中性卡面、无分隔线、卡间留白。
    /// 行背景用不透明底色（与列表底同色）而非 clear —— 这样横滑操作会渲染成
    /// 齐边的整块色带（而不是悬浮的小药丸/圆钮）。
    /// plain 列表的 section 头部：与卡片同边距对齐、清掉默认高亮底。
    func sectionHeaderInset() -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets(top: 10, leading: Theme.Space.page, bottom: 4, trailing: Theme.Space.page))
            .listRowBackground(Color.clear)
    }

    func cardCell(pad: CGFloat = Theme.Space.cardPad) -> some View {
        self
            .cardStyle(pad: pad)
            .listRowBackground(Theme.screen)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 5, leading: Theme.Space.page, bottom: 5, trailing: Theme.Space.page))
    }

    /// 按开关决定是否挂长按菜单：首页卡片传 false 关掉长按抬起效果
    @ViewBuilder
    func contextMenuIf<M: View>(_ enabled: Bool, @ViewBuilder menu: () -> M) -> some View {
        if enabled { self.contextMenu(menuItems: menu) } else { self }
    }
}

/// 分类图标块：渐变分类色 + 白色 SF Symbol（Settings / App Store 式），给卡片加强识别色。
struct IconChip: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 38

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: .rect(cornerRadius: size * 0.28))
    }
}

/// 快递承运商图标：立体牛皮纸箱 + 哑光品牌色宽胶带（带撕口）+ 品牌色面单。
/// 说明：各快递真实 logo 是注册商标，故用「统一风格 + 品牌色 + 首字面单」来指代而非复刻。
/// 识别不出的承运商退回通用蓝色胶带、不贴面单。全部用 Canvas 在 100×100 逻辑坐标里绘制后缩放。
struct CarrierIcon: View {
    let carrier: String?
    var size: CGFloat = 38

    /// 承运商 → (品牌色, 面单字号)。按 carrier 全名 contains 关键字匹配。
    private static let styles: [(key: String, color: Color, mark: String)] = [
        ("顺丰", Color(red: 0.184, green: 0.192, blue: 0.227), "顺"),
        ("京东", Color(red: 0.902, green: 0.224, blue: 0.275), "京"),
        ("圆通", Color(red: 0.392, green: 0.380, blue: 0.863), "圆"),
        ("中通", Color(red: 0.102, green: 0.549, blue: 0.878), "中"),
        ("申通", Color(red: 0.200, green: 0.714, blue: 0.788), "申"),
        ("韵达", Color(red: 1.000, green: 0.624, blue: 0.039), "韵"),
        ("极兔", Color(red: 0.878, green: 0.290, blue: 0.408), "兔"),
        ("德邦", Color(red: 0.604, green: 0.396, blue: 0.157), "德"),
        ("EMS", Color(red: 0.059, green: 0.620, blue: 0.416), "E"),
        ("邮政", Color(red: 0.059, green: 0.620, blue: 0.416), "邮"),
    ]

    private var style: (color: Color, mark: String)? {
        guard let carrier else { return nil }
        return Self.styles.first { carrier.contains($0.key) }.map { ($0.color, $0.mark) }
    }

    // 牛皮三面与描边色（与预览一致）
    private static let front  = Color(red: 0.808, green: 0.659, blue: 0.482)
    private static let top    = Color(red: 0.922, green: 0.792, blue: 0.592)
    private static let side   = Color(red: 0.733, green: 0.573, blue: 0.396)
    private static let base   = Color(red: 0.765, green: 0.612, blue: 0.435)
    private static let edge   = Color(red: 0.471, green: 0.314, blue: 0.149)
    private static let shadow = Color(red: 0.420, green: 0.290, blue: 0.118)

    var body: some View {
        let s = style
        let brand = s?.color ?? Theme.express
        Canvas { ctx, sz in
            // 纸箱包围盒 (20,32)-(86,86)，放大居中填满画布、消掉四周留白；线宽字号随之等比放大
            let k = sz.width / 100
            let bw: CGFloat = 66, bh: CGFloat = 54          // 包围盒宽高
            let scale = 92 / bw                             // 横向填到 92，两侧留 4 给圆角/阴影
            ctx.scaleBy(x: k, y: k)                         // 逻辑 100 空间 → 设备像素
            ctx.translateBy(x: (100 - bw * scale) / 2, y: (100 - bh * scale) / 2)
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -20, y: -32)                 // 包围盒原点移到画布原点
            func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

            // 圆润外轮廓（圆角4/平滑1）
            let outline = Self.roundedOutline(
                [P(20, 86), P(20, 44), P(34, 32), P(86, 32), P(86, 74), P(72, 86)],
                r: 4, k: 0.34 + 1.0 * 0.42)

            // 柔和阴影
            ctx.drawLayer { layer in
                layer.addFilter(.shadow(color: Self.shadow.opacity(0.22), radius: 3.2, x: 0, y: 2.5))
                layer.fill(outline, with: .color(Self.base))
            }

            // 裁到圆润轮廓，画三面 + 胶带 + 棱线（内部锐利拼接）
            var inner = ctx
            inner.clip(to: outline)
            inner.fill(Self.poly([P(20, 44), P(72, 44), P(72, 86), P(20, 86)]), with: .color(Self.front))
            inner.fill(Self.poly([P(20, 44), P(72, 44), P(86, 32), P(34, 32)]), with: .color(Self.top))
            inner.fill(Self.poly([P(72, 44), P(86, 32), P(86, 74), P(72, 86)]), with: .color(Self.side))

            // 顶面胶带 + 受光提亮
            let topTape = Self.poly([P(28, 44), P(40, 44), P(54, 32), P(42, 32)])
            inner.fill(topTape, with: .color(brand))
            inner.fill(topTape, with: .color(.white.opacity(0.1)))
            // 正面哑光胶带，底端锐利撕口
            inner.fill(Self.poly([P(28, 44), P(40, 44), P(40, 78), P(38.5, 81.8), P(37, 78),
                                  P(35.5, 81.8), P(34, 78), P(32.5, 81.8), P(31, 78),
                                  P(29.5, 81.8), P(28, 78)]), with: .color(brand))
            // 胶带两侧暗影
            inner.fill(Path(CGRect(x: 28, y: 44, width: 0.9, height: 34)), with: .color(.black.opacity(0.08)))
            inner.fill(Path(CGRect(x: 39.1, y: 44, width: 0.9, height: 34)), with: .color(.black.opacity(0.08)))

            // 三条棱线勾出立体折面
            var fold = Path()
            fold.move(to: P(20, 44)); fold.addLine(to: P(72, 44))
            fold.move(to: P(72, 44)); fold.addLine(to: P(86, 32))
            fold.move(to: P(72, 44)); fold.addLine(to: P(72, 86))
            inner.stroke(fold, with: .color(Self.edge.opacity(0.30)),
                         style: StrokeStyle(lineWidth: 0.9, lineCap: .round))

            // 外轮廓描边（不裁，收干净）
            ctx.stroke(outline, with: .color(Self.edge.opacity(0.22)), lineWidth: 0.8)

            // 品牌色面单（识别不出则不贴）
            if let mark = s?.mark {
                let card = Path(roundedRect: CGRect(x: 45, y: 52, width: 25, height: 28), cornerRadius: 6)
                ctx.fill(card, with: .color(.white))
                ctx.stroke(card, with: .color(.black.opacity(0.10)), lineWidth: 1)
                ctx.draw(Text(mark).font(.system(size: 15, weight: .heavy)).foregroundColor(brand),
                         at: P(57.5, 64), anchor: .center)
                // 面单条码
                let bars: [(CGFloat, CGFloat)] = [(48, 1.4), (50.4, 0.8), (52.2, 1.8), (55, 0.8),
                                                  (56.8, 1.4), (59.2, 0.8), (61, 1.8), (63.8, 1.0), (65.6, 1.4)]
                for (x, w) in bars {
                    ctx.fill(Path(CGRect(x: x, y: 72.5, width: w, height: 5)),
                             with: .color(Color(red: 0.27, green: 0.27, blue: 0.27)))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(carrier ?? "快递")
    }

    /// 锐利多边形（内部三面严丝合缝拼接用）
    private static func poly(_ pts: [CGPoint]) -> Path {
        var p = Path(); p.addLines(pts); p.closeSubpath(); return p
    }

    /// 连续曲率圆角多边形：每个角用三次贝塞尔，控制点按 k 拉伸（接近 iOS squircle）。
    private static func roundedOutline(_ pts: [CGPoint], r: CGFloat, k: CGFloat) -> Path {
        let n = pts.count
        var a = [CGPoint](), b = [CGPoint](), c1 = [CGPoint](), c2 = [CGPoint]()
        for i in 0..<n {
            let p0 = pts[(i - 1 + n) % n], p1 = pts[i], p2 = pts[(i + 1) % n]
            let v1 = CGPoint(x: p0.x - p1.x, y: p0.y - p1.y)
            let v2 = CGPoint(x: p2.x - p1.x, y: p2.y - p1.y)
            let l1 = hypot(v1.x, v1.y), l2 = hypot(v2.x, v2.y)
            let rr = min(r, l1 * 0.5, l2 * 0.5)
            let pa = CGPoint(x: p1.x + v1.x / l1 * rr, y: p1.y + v1.y / l1 * rr)
            let pb = CGPoint(x: p1.x + v2.x / l2 * rr, y: p1.y + v2.y / l2 * rr)
            a.append(pa); b.append(pb)
            c1.append(CGPoint(x: pa.x + (p1.x - pa.x) * k, y: pa.y + (p1.y - pa.y) * k))
            c2.append(CGPoint(x: pb.x + (p1.x - pb.x) * k, y: pb.y + (p1.y - pb.y) * k))
        }
        var path = Path()
        path.move(to: a[0])
        for i in 0..<n {
            path.addCurve(to: b[i], control1: c1[i], control2: c2[i])
            path.addLine(to: a[(i + 1) % n])
        }
        path.closeSubpath()
        return path
    }
}

/// 状态标签：淡底 tinted 胶囊（明确是"标签"而非可点链接）
struct StatusTag: View {
    let text: String
    var color: Color = Theme.sub

    var body: some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
    }
}

/// 右下角悬浮新增按钮：待办 / 收藏统一的「+」入口。
/// 放在页面 ZStack 的 bottomTrailing。
struct FloatingAddButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Theme.accent.gradient, in: Circle())
                .shadow(color: Theme.accent.opacity(0.35), radius: 8, y: 4)
        }
        .buttonStyle(PressableStyle(scale: 0.94))
        .padding(.trailing, Theme.Space.page)
        .padding(.bottom, 18)
        .accessibilityLabel("新增")
    }
}

// MARK: - 待办优先级

/// 待办优先级：数值对齐滴答清单（0 无 / 1 低 / 3 中 / 5 高），可排序、可同步。
/// 存储用 `InboxItem.todoPriority`(Int)，这里只做展示映射。
enum TodoPriority: Int, CaseIterable, Identifiable {
    case none = 0, low = 1, medium = 3, high = 5

    /// 从存储的原始值构造（无法识别的值归为无优先级）
    init(raw: Int) { self = TodoPriority(rawValue: raw) ?? .none }

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .none:   "无优先级"
        case .low:    "低优先级"
        case .medium: "中优先级"
        case .high:   "高优先级"
        }
    }

    /// 旗标颜色，与滴答一致：高=红 / 中=黄 / 低=蓝 / 无=灰
    var color: Color {
        switch self {
        case .none:   Color(.tertiaryLabel)
        case .low:    Color(.systemBlue)
        case .medium: Color(.systemYellow)
        case .high:   Color(.systemRed)
        }
    }
}

/// 优先级选择器：一排四个旗标（高/中/低/无），选中项高亮。用于新增/编辑弹窗。
struct TodoPriorityPicker: View {
    @Binding var priority: Int

    var body: some View {
        HStack(spacing: 10) {
            ForEach([TodoPriority.high, .medium, .low, .none]) { p in
                let selected = p.rawValue == priority
                Button {
                    withAnimation(.snappy(duration: 0.15)) { priority = p.rawValue }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "flag.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(p.color)
                        Text(shortLabel(p))
                            .font(.caption2)
                            .foregroundStyle(selected ? Theme.text : Theme.sub)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(selected ? p.color.opacity(0.14) : Theme.fill,
                               in: .rect(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(selected ? p.color.opacity(0.55) : .clear, lineWidth: 1.5)
                    }
                }
                .buttonStyle(PressableStyle())
            }
        }
    }

    private func shortLabel(_ p: TodoPriority) -> String {
        switch p {
        case .none: "无"; case .low: "低"; case .medium: "中"; case .high: "高"
        }
    }
}

/// 截止时间选择器：一排快捷时间瓦片（今天/明天/下周一/今天傍晚）+ 展开的图形日期选择。
/// 用 `Date?` 绑定：nil = 无截止。用于新增/编辑弹窗，替代裸 Toggle+DatePicker。
struct TodoDuePicker: View {
    @Binding var due: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                quickTile("今天", "calendar", .systemRed, date: startOfToday)
                quickTile("明天", "sunrise.fill", .systemOrange, date: dayAfter(startOfToday, 1))
                quickTile("下周一", "arrow.right.circle.fill", .systemBlue, date: nextMonday)
                quickTile("今天傍晚", "moon.fill", .systemIndigo, date: todayEvening)
            }

            if let current = due {
                DatePicker(
                    "",
                    selection: Binding(get: { current }, set: { due = $0 }),
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.graphical)
                .labelsHidden()
                .tint(Theme.accent)

                Button {
                    withAnimation(.snappy) { due = nil }
                } label: {
                    Label("清除截止时间", systemImage: "xmark.circle.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.red)
                }
                .buttonStyle(PressableStyle())
            }
        }
    }

    private func quickTile(_ title: String, _ icon: String, _ color: UIColor, date: Date) -> some View {
        let tint = Color(color)
        // 精确到分钟比对，避免「今天」和「今天傍晚」同日互相误高亮
        let selected = due.map { Calendar.current.isDate($0, equalTo: date, toGranularity: .minute) } ?? false
        return Button {
            withAnimation(.snappy) { due = date }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 17))
                    .foregroundStyle(selected ? .white : tint)
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(selected ? .white : Theme.text)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(selected ? tint : Theme.fill,
                        in: .rect(cornerRadius: 12))
        }
        .buttonStyle(PressableStyle())
    }

    private var startOfToday: Date { Calendar.current.startOfDay(for: Date()) }

    private func dayAfter(_ date: Date, _ days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: date) ?? date
    }

    /// 今天傍晚 18:00
    private var todayEvening: Date {
        Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: Date()) ?? Date()
    }

    /// 下一个周一（若今天就是周一，取下周一）
    private var nextMonday: Date {
        let cal = Calendar.current
        let today = startOfToday
        // 周一 = 2（周日为 1）
        let weekday = cal.component(.weekday, from: today)
        let delta = ((9 - weekday) % 7)
        let offset = delta == 0 ? 7 : delta
        return cal.date(byAdding: .day, value: offset, to: today) ?? today
    }
}

/// 轻量彩色文字标签（用于 tag、次要标记）
struct Badge: View {
    let text: String
    var color: Color = Theme.sub

    var body: some View {
        Text(text)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(color)
    }
}

/// 首页分区头：分类色小图标 + 标题 + 计数。小号彩色 SF Symbol（不是填充色块），加识别度不显廉价。
struct SectionHeader: View {
    let icon: String
    let tint: Color
    let title: String
    var count: String? = nil

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(tint)
            Text(title).font(.headline)
            if let count {
                Text(count).font(.subheadline).foregroundStyle(Theme.sub)
            }
            Spacer()
        }
        .textCase(nil)
    }
}
