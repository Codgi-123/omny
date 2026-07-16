import SwiftUI

/// 记账消费分类的「外观」映射：分类名 → (图标, 签名色)。
///
/// 设计要点：与分类池数据（`AppSettings.expenseCategoryPool: [String:[String]]`）**解耦**。
/// 分类池只存名字、供 LLM 打标；外观是纯展示层的另一张表，按名字查图标+色。
/// 好处：OmnyCore（LLMExpenseCategorizer / Models / 去重）零改动，用户改分类名也不影响打标逻辑。
///
/// 图标是 Assets 里的自绘 SVG 线稿（ExpIcon* 系列，24×24、1.8pt 圆头描边，与收藏页
/// BookmarkLink/BookmarkNote 同一套风格），template 渲染可随意着色；
/// 旧版用户覆盖存过 SF Symbol 名，`CategoryIcon.symbol` 保留向后兼容。
///
/// 三层兜底（查外观顺序）：
///   1. 用户自定义覆盖（存 UserDefaults，「消费分类」页自定义时写入）
///   2. 内置预置库（覆盖默认池全部大类+细分，外加常见自定义分类名）
///   3. 通用兜底：ExpIconTag + 按名 hash 从签名色板稳定取一色（保证任意分类都有稳定外观）
///
/// 用法：`ExpenseCategoryAppearance.shared.appearance(major:sub:)` 拿到 (icon, color)，
/// 喂给 `ExpenseCategoryChip` / `CategoryIconGlyph` 渲染。
enum CategoryIcon: Hashable {
    case asset(String)   // 自绘 SVG 资产名（ExpIcon*）
    case symbol(String)  // SF Symbol 名（旧用户覆盖兼容）
}

struct CategoryAppearance {
    let icon: CategoryIcon
    let color: Color
}

@MainActor
final class ExpenseCategoryAppearance {
    static let shared = ExpenseCategoryAppearance()
    private let defaults = UserDefaults.standard
    /// [分类名: "svg:资产名|colorKey"]；旧格式 "SF名|colorKey" 仍可解析
    private let userKey = "expense.categoryAppearance"

    private init() {}

    // MARK: 对外主入口

    /// 查一笔记账的图标外观：优先细分专属图标，其次大类，最后兜底。
    /// 颜色统一取「大类」的签名色——同一大类下的细分共用大类色，符合"按大类分色统计"的直觉。
    func appearance(major: String?, sub: String? = nil) -> CategoryAppearance {
        let color = majorColor(major)
        let icon = namedIcon(sub) ?? namedIcon(major) ?? Self.fallbackIcon
        return CategoryAppearance(icon: icon, color: color)
    }

    /// 读某分类名当前生效的图标（供选择器回显：用户覆盖 → 预置 → 兜底）
    func currentIcon(major: String?, sub: String? = nil) -> CategoryIcon {
        appearance(major: major, sub: sub).icon
    }

    // MARK: 单名字查图标（细分/大类同一张预置表）

    private func namedIcon(_ name: String?) -> CategoryIcon? {
        guard let name, !name.isEmpty else { return nil }
        if let user = userOverride(name)?.icon { return user }
        if let asset = Self.presetIcons[name] { return .asset(asset) }
        return nil
    }

    /// 大类色：用户覆盖 → 预置 → 按名 hash 兜底取色。任何非空大类都有稳定颜色。
    private func majorColor(_ major: String?) -> Color {
        guard let major, !major.isEmpty else { return Theme.ExpenseColor.other }
        if let user = userOverride(major)?.color { return user }
        if let preset = Self.majorColors[major] { return preset }
        return Self.hashedColor(for: major)
    }

    // MARK: 通用兜底

    static let fallbackIcon = CategoryIcon.asset("ExpIconTag")

    /// 按名字稳定 hash 落到签名色板的一色（同名永远同色，跨启动稳定）。
    /// 不用 Swift 的 hashValue（每次启动加盐、不稳定），用简单的字符累加。
    static func hashedColor(for name: String) -> Color {
        let sum = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        let palette = Theme.ExpenseColor.palette
        return palette[sum % palette.count]
    }

    // MARK: 用户覆盖

    private func userOverride(_ name: String) -> CategoryAppearance? {
        guard let map = defaults.dictionary(forKey: userKey) as? [String: String],
              let raw = map[name] else { return nil }
        // 存储格式 "icon|colorKey"：icon 带 "svg:" 前缀是自绘资产，否则当旧 SF Symbol；
        // colorKey 优先按签名色 key 映射（保留深色适配），查不到再当旧 hex 兜底解析。
        let parts = raw.components(separatedBy: "|")
        let icon: CategoryIcon? = parts.first.flatMap { head in
            guard !head.isEmpty else { return nil }
            if head.hasPrefix("svg:") { return .asset(String(head.dropFirst(4))) }
            return .symbol(head)
        }
        let color: Color? = {
            guard parts.count > 1, !parts[1].isEmpty else { return nil }
            return Theme.ExpenseColor.color(forKey: parts[1]) ?? Color(hex: parts[1])
        }()
        guard icon != nil || color != nil else { return nil }
        return CategoryAppearance(icon: icon ?? Self.fallbackIcon,
                                  color: color ?? Self.hashedColor(for: name))
    }

    // MARK: 写入用户覆盖（「消费分类」页自定义时调用）

    /// 记住某分类名的图标 + 颜色 key。colorKey 传 Theme.ExpenseColor.keys 之一（细分传空沿用大类色）。
    func setOverride(name: String, icon: CategoryIcon, colorKey: String) {
        var map = (defaults.dictionary(forKey: userKey) as? [String: String]) ?? [:]
        let head: String = switch icon {
        case .asset(let n): "svg:\(n)"
        case .symbol(let n): n
        }
        map[name] = "\(head)|\(colorKey)"
        defaults.set(map, forKey: userKey)
    }

    /// 删除某分类名的覆盖（删分类时清理）
    func removeOverride(name: String) {
        guard var map = defaults.dictionary(forKey: userKey) as? [String: String] else { return }
        map.removeValue(forKey: name)
        defaults.set(map, forKey: userKey)
    }

    // MARK: - 内置预置库

    /// 分类名 → 自绘 SVG 资产名。大类、细分同表（名字不冲突）；
    /// 默认池之外多备了一批常见自定义分类名（旅行/宠物/教育…），新建同名分类自动有贴切图标。
    static let presetIcons: [String: String] = [
        // 大类
        "餐饮": "ExpIconFood", "交通": "ExpIconCar", "购物": "ExpIconShopping",
        "居家": "ExpIconHome", "娱乐": "ExpIconGame", "医疗": "ExpIconMedical",
        "收入": "ExpIconMoneyBag",
        // 餐饮细分
        "早餐": "ExpIconBreakfast", "午餐": "ExpIconLunch", "晚餐": "ExpIconDinner",
        "外卖": "ExpIconTakeout", "咖啡零食": "ExpIconCoffee",
        // 交通细分
        "打车": "ExpIconTaxi", "公交地铁": "ExpIconMetro", "加油": "ExpIconFuel", "停车": "ExpIconParking",
        // 购物细分
        "日用": "ExpIconDaily", "服饰": "ExpIconClothes", "数码": "ExpIconLaptop", "家居": "ExpIconSofa",
        // 居家细分
        "房租": "ExpIconKey", "水电燃气": "ExpIconBolt", "物业": "ExpIconBuilding",
        // 娱乐细分
        "订阅": "ExpIconSubscribe", "游戏": "ExpIconGame", "电影": "ExpIconMovie",
        // 医疗细分
        "门诊": "ExpIconClinic", "药品": "ExpIconPills",
        // 收入细分
        "工资": "ExpIconBanknote", "报销": "ExpIconReceipt", "退款": "ExpIconRefund",
        "其他": "ExpIconOther",
        // 常见自定义分类名（默认池没有，建同名分类时自动命中）
        "旅行": "ExpIconPlane", "宠物": "ExpIconPaw", "教育": "ExpIconBook",
        "学习": "ExpIconBook", "通讯": "ExpIconPhone", "话费": "ExpIconPhone",
        "人情": "ExpIconHeart", "运动": "ExpIconSport", "健身": "ExpIconSport",
        "投资": "ExpIconChart", "理财": "ExpIconChart", "红包": "ExpIconRedPacket",
        "美容": "ExpIconScissors", "理发": "ExpIconScissors", "母婴": "ExpIconBaby",
        "酒水": "ExpIconWine", "甜品": "ExpIconCake", "礼物": "ExpIconGift",
        "奖金": "ExpIconGift", "办公": "ExpIconLaptop",
    ]

    /// 大类 → 签名色
    static let majorColors: [String: Color] = [
        "餐饮": Theme.ExpenseColor.food,
        "交通": Theme.ExpenseColor.trans,
        "购物": Theme.ExpenseColor.shopping,
        "居家": Theme.ExpenseColor.home,
        "娱乐": Theme.ExpenseColor.fun,
        "医疗": Theme.ExpenseColor.medical,
        "收入": Theme.ExpenseColor.income,
    ]

    /// 图标选择器候选库：全部自绘 SVG 资产，按语义分组排序。
    /// 用户新建/编辑分类时从这里挑。
    static let pickerIcons: [String] = [
        // 餐饮
        "ExpIconFood", "ExpIconBreakfast", "ExpIconLunch", "ExpIconDinner",
        "ExpIconTakeout", "ExpIconCoffee", "ExpIconCake", "ExpIconWine",
        // 交通 / 出行
        "ExpIconCar", "ExpIconTaxi", "ExpIconMetro", "ExpIconFuel", "ExpIconParking", "ExpIconPlane",
        // 购物 / 生活
        "ExpIconShopping", "ExpIconDaily", "ExpIconClothes", "ExpIconLaptop", "ExpIconSofa",
        "ExpIconGift", "ExpIconScissors", "ExpIconBaby", "ExpIconPaw",
        // 居家
        "ExpIconHome", "ExpIconKey", "ExpIconBolt", "ExpIconBuilding",
        // 娱乐 / 文体
        "ExpIconGame", "ExpIconSubscribe", "ExpIconMovie", "ExpIconBook", "ExpIconSport",
        // 医疗
        "ExpIconMedical", "ExpIconClinic", "ExpIconPills",
        // 收入 / 金融
        "ExpIconMoneyBag", "ExpIconBanknote", "ExpIconReceipt", "ExpIconRefund",
        "ExpIconChart", "ExpIconRedPacket",
        // 通用
        "ExpIconPhone", "ExpIconHeart", "ExpIconOther", "ExpIconTag",
    ]
}

// MARK: - Color(hex:) 便捷初始化（供用户覆盖存色用）

private extension Color {
    /// 从 "RRGGBB" / "#RRGGBB" 解析；失败返回灰（不崩，兜底靠上层 hash 色覆盖）
    init(hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var v: UInt64 = 0
        guard s.count == 6, Scanner(string: s).scanHexInt64(&v) else {
            self = Color(.systemGray); return
        }
        self = Color(red: Double((v >> 16) & 0xFF) / 255,
                     green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255)
    }
}
