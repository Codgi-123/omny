import SwiftUI

/// 记账分类图标 chip：圆形中性灰底 + 灰线稿。
/// 列表行/详情/分析排行/记一笔宫格统一用它——分类色只留给图表（环状图扇区、占比进度条），
/// 图标不带彩色底（彩底成排出现太吵，用户明确否掉；灰底形状定为圆形也是用户拍板）。
struct ExpenseCategoryChip: View {
    let appearance: CategoryAppearance
    var size: CGFloat = 38

    var body: some View {
        CategoryIconGlyph(icon: appearance.icon, pointSize: size * 0.56)
            .foregroundStyle(Theme.sub)
            .frame(width: size, height: size)
            .background(Theme.sub.opacity(0.1), in: Circle())
    }
}

/// 裸分类图标线稿（无底色块）：记一笔宫格未选中态、图标选择器用。
/// 颜色跟随环境 foregroundStyle（资产是 template 渲染）。
struct CategoryIconGlyph: View {
    let icon: CategoryIcon
    var pointSize: CGFloat = 22

    var body: some View {
        switch icon {
        case .asset(let name):
            Image(name)
                .resizable()
                .scaledToFit()
                .frame(width: pointSize, height: pointSize)
        case .symbol(let name):
            // 旧用户覆盖的 SF Symbol：字号按视觉大小折算（SF 的 em 框小于点阵框）
            Image(systemName: name)
                .font(.system(size: pointSize * 0.82, weight: .medium))
        }
    }
}
