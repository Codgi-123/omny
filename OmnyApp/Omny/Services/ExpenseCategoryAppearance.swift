import SwiftUI

/// 记账消费分类的「外观」映射：分类名 → (SF Symbol, 签名色)。
///
/// 设计要点：与分类池数据（`AppSettings.expenseCategoryPool: [String:[String]]`）**解耦**。
/// 分类池只存名字、供 LLM 打标；外观是纯展示层的另一张表，按名字查图标+色。
/// 好处：OmnyCore（LLMExpenseCategorizer / Models / 去重）零改动，用户改分类名也不影响打标逻辑。
///
/// 三层兜底（查外观顺序）：
///   1. 用户自定义覆盖（存 UserDefaults，设置页自定义分类时写入）——本期先留接口，UI 后补
///   2. 内置预置库（覆盖默认池全部大类 + 常见细分）
///   3. 通用兜底：`tag.fill` + 按名 hash 从签名色板稳定取一色（保证任意分类都有稳定外观）
///
/// 用法：`ExpenseCategoryAppearance.shared.appearance(major:sub:)` 拿到 (symbol, color)，
/// 直接喂给现有 `IconChip(symbol:color:)`。
struct CategoryAppearance {
    let symbol: String
    let color: Color
}

@MainActor
final class ExpenseCategoryAppearance {
    static let shared = ExpenseCategoryAppearance()
    private let defaults = UserDefaults.standard
    private let userKey = "expense.categoryAppearance"  // [分类名: "symbol|colorHex"]（本期未写入，接口预留）

    private init() {}

    // MARK: 对外主入口

    /// 查一笔记账的图标外观：优先细分专属图标，其次大类，最后兜底。
    /// 颜色统一取「大类」的签名色——同一大类下的细分共用大类色，符合"按大类分色统计"的直觉。
    func appearance(major: String?, sub: String? = nil) -> CategoryAppearance {
        let color = majorColor(major)
        // 图标：细分有专属图标优先用（更具体），否则用大类图标，再否则兜底
        let symbol = subSymbol(major: major, sub: sub)
            ?? majorSymbol(major)
            ?? Self.fallbackSymbol
        return CategoryAppearance(symbol: symbol, color: color)
    }

    // MARK: 大类外观

    private func majorSymbol(_ major: String?) -> String? {
        guard let major, !major.isEmpty else { return nil }
        if let user = userOverride(major)?.symbol { return user }
        return Self.majorSymbols[major]
    }

    /// 大类色：用户覆盖 → 预置 → 按名 hash 兜底取色。任何非空大类都有稳定颜色。
    private func majorColor(_ major: String?) -> Color {
        guard let major, !major.isEmpty else { return Theme.ExpenseColor.other }
        if let user = userOverride(major)?.color { return user }
        if let preset = Self.majorColors[major] { return preset }
        return Self.hashedColor(for: major)
    }

    // MARK: 细分外观

    private func subSymbol(major: String?, sub: String?) -> String? {
        guard let sub, !sub.isEmpty else { return nil }
        if let user = userOverride(sub)?.symbol { return user }
        return Self.subSymbols[sub]
    }

    // MARK: 通用兜底

    static let fallbackSymbol = "tag.fill"

    /// 按名字稳定 hash 落到签名色板的一色（同名永远同色，跨启动稳定）。
    /// 不用 Swift 的 hashValue（每次启动加盐、不稳定），用简单的字符累加。
    static func hashedColor(for name: String) -> Color {
        let sum = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        let palette = Theme.ExpenseColor.palette
        return palette[sum % palette.count]
    }

    // MARK: 用户覆盖（本期接口预留，设置页自定义 UI 后补写入）

    private func userOverride(_ name: String) -> CategoryAppearance? {
        guard let map = defaults.dictionary(forKey: userKey) as? [String: String],
              let raw = map[name] else { return nil }
        // 存储格式 "symbol|colorKey"：colorKey 优先按签名色 key 映射（保留深色适配），
        // 查不到再当作旧的 hex 兜底解析。
        let parts = raw.components(separatedBy: "|")
        let symbol = parts.first.flatMap { $0.isEmpty ? nil : $0 }
        let color: Color? = {
            guard parts.count > 1, !parts[1].isEmpty else { return nil }
            return Theme.ExpenseColor.color(forKey: parts[1]) ?? Color(hex: parts[1])
        }()
        guard symbol != nil || color != nil else { return nil }
        return CategoryAppearance(symbol: symbol ?? Self.fallbackSymbol,
                                  color: color ?? Self.hashedColor(for: name))
    }

    // MARK: 写入用户覆盖（设置页自定义分类时调用）

    /// 记住某分类名的图标 + 颜色 key。colorKey 传 Theme.ExpenseColor.keys 之一。
    func setOverride(name: String, symbol: String, colorKey: String) {
        var map = (defaults.dictionary(forKey: userKey) as? [String: String]) ?? [:]
        map[name] = "\(symbol)|\(colorKey)"
        defaults.set(map, forKey: userKey)
    }

    /// 删除某分类名的覆盖（删分类时清理）
    func removeOverride(name: String) {
        guard var map = defaults.dictionary(forKey: userKey) as? [String: String] else { return }
        map.removeValue(forKey: name)
        defaults.set(map, forKey: userKey)
    }

    /// 读某分类名当前生效的图标（供选择器回显：用户覆盖 → 预置 → 兜底）
    func currentSymbol(major: String?, sub: String? = nil) -> String {
        appearance(major: major, sub: sub).symbol
    }

    // MARK: - 内置预置库（覆盖 AppSettings.defaultExpenseCategoryPool 全部大类 + 常见细分）

    /// 大类 → SF Symbol
    static let majorSymbols: [String: String] = [
        "餐饮": "fork.knife",
        "交通": "car.fill",
        "购物": "bag.fill",
        "居家": "house.fill",
        "娱乐": "gamecontroller.fill",
        "医疗": "cross.case.fill",
        "收入": "yensign.circle.fill",
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

    /// 细分 → SF Symbol（有专属就用，覆盖默认池的细分；未列的细分回退到大类图标）
    static let subSymbols: [String: String] = [
        // 餐饮
        "早餐": "sunrise.fill", "午餐": "fork.knife", "晚餐": "moon.stars.fill",
        "外卖": "takeoutbag.and.cup.and.straw.fill", "咖啡零食": "cup.and.saucer.fill",
        // 交通
        "打车": "car.fill", "公交地铁": "tram.fill", "加油": "fuelpump.fill", "停车": "parkingsign",
        // 购物
        "日用": "basket.fill", "服饰": "tshirt.fill", "数码": "laptopcomputer", "家居": "sofa.fill",
        // 居家
        "房租": "key.fill", "水电燃气": "bolt.fill", "物业": "building.2.fill",
        // 娱乐
        "订阅": "rectangle.stack.fill", "游戏": "gamecontroller.fill", "电影": "film.fill",
        // 医疗
        "门诊": "stethoscope", "药品": "pills.fill",
        // 收入
        "工资": "banknote.fill", "报销": "doc.text.fill", "退款": "arrow.uturn.backward.circle.fill",
        "其他": "ellipsis.circle.fill",
    ]

    /// 图标选择器候选库：精选常见消费/收入类 SF Symbol（不做全量浏览器，够用即可）。
    /// 用户新建/编辑分类时从这里挑。逐个在真机核对存在性（个别旧系统可能缺，缺则显示空白，不崩）。
    static let pickerSymbols: [String] = [
        // 餐饮
        "fork.knife", "cup.and.saucer.fill", "takeoutbag.and.cup.and.straw.fill", "birthday.cake.fill", "wineglass.fill",
        // 交通
        "car.fill", "tram.fill", "bus.fill", "fuelpump.fill", "parkingsign", "airplane", "bicycle",
        // 购物
        "bag.fill", "cart.fill", "basket.fill", "tshirt.fill", "handbag.fill", "gift.fill",
        // 居家 / 数码
        "house.fill", "sofa.fill", "bolt.fill", "key.fill", "laptopcomputer", "iphone", "lightbulb.fill",
        // 娱乐 / 生活
        "gamecontroller.fill", "film.fill", "music.note", "book.fill", "figure.run", "pawprint.fill",
        // 医疗 / 教育
        "cross.case.fill", "pills.fill", "stethoscope", "graduationcap.fill",
        // 收入 / 金融
        "yensign.circle.fill", "banknote.fill", "creditcard.fill", "chart.line.uptrend.xyaxis", "gift.circle.fill",
        // 通用
        "tag.fill", "star.fill", "heart.fill", "briefcase.fill", "ellipsis.circle.fill",
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
