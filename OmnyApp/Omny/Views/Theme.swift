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

        /// 稳定 key ↔ 色：用户自选色时存 key（非 hex），渲染时映射回动态色（保留深色适配）。
        /// 顺序与 palette 一致，供颜色选择器展示。
        static let keys: [String] = ["food", "trans", "shopping", "home", "fun", "medical", "income", "other"]
        static func color(forKey key: String) -> Color? {
            switch key {
            case "food": food; case "trans": trans; case "shopping": shopping; case "home": home
            case "fun": fun; case "medical": medical; case "income": income; case "other": other
            default: nil
            }
        }
    }

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

    /// 独立富卡片作为 plain List 行：加中性卡面、清行背景、无分隔线、卡间留白
    func cardCell() -> some View {
        self
            .cardStyle()
            .listRowBackground(Color.clear)
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
