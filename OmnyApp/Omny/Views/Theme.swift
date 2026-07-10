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

    /// 统一的间距刻度（4/8pt 栅格）
    enum Space {
        static let page: CGFloat = 16
        static let gap: CGFloat = 12
        static let cardPad: CGFloat = 16
    }
}

// MARK: 通用组件

/// 卡片表面：中性单元格底 + 柔和阴影托出层次（App Store 卡片式的"浮起"质感，非旧的描边+阴影堆叠）。
struct CardBackground: ViewModifier {
    var warm = false
    func body(content: Content) -> some View {
        content
            .padding(Theme.Space.cardPad)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
    func cardStyle(warm: Bool = false) -> some View {
        modifier(CardBackground(warm: warm))
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
    func cardCell() -> some View {
        self
            .cardStyle()
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
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
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
        .buttonStyle(.plain)
        .padding(.trailing, Theme.Space.page)
        .padding(.bottom, 18)
        .accessibilityLabel("新增")
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
