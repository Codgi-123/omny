import SwiftUI

// MARK: - 可折叠分组头

/// 可折叠分组头：待办页「优先级 / 已完成 / 已放弃」分组原本各自复制一份的头部，收编到这里。
/// 点整行切换展开态（组件内自带 .snappy 动画）；chevron 按 HIG disclosure 惯例：
/// 收起指右、展开指下，旋转动画过渡。
/// 只管头部外观与切换交互；行内容的显隐仍由调用方按 expanded 值控制；
/// List 里的行内边距（.sectionHeaderInset()）也由调用方按场景自加。
struct CollapsibleSectionHeader<Leading: View>: View {
    let title: String
    let count: Int
    @Binding var expanded: Bool
    /// 可选前置视图（如优先级组的旗标图标），默认为空
    @ViewBuilder var leading: () -> Leading

    var body: some View {
        Button {
            withAnimation(.snappy) { expanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                leading()
                Text(title)
                Text("\(count)").foregroundStyle(Theme.sub)
                Spacer()
                // chevron.down 即「展开指下」；收起时逆时针转 90° 指右
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.sub)
                    .rotationEffect(.degrees(expanded ? 0 : -90))
            }
            .font(.subheadline.weight(.medium))
            .textCase(nil)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension CollapsibleSectionHeader where Leading == EmptyView {
    /// 无前置图标的便捷构造（已完成 / 已放弃分组用）
    init(title: String, count: Int, expanded: Binding<Bool>) {
        self.init(title: title, count: count, expanded: expanded) { EmptyView() }
    }
}
