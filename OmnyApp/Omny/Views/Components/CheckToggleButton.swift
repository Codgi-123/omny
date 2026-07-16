import SwiftUI

// MARK: - 勾选按钮（快递取件圈 / 待办完成勾选同款外观底座）

/// 圆圈/方框类勾选按钮的统一外观：symbol 替换动画 + 按压缩放 + 保底 44pt 命中区。
/// 勾选后的业务语义（取件的双向状态推进、待办的完成/撤销放弃、滴答标脏回写）
/// 全部由调用方 action 闭包承载；触感反馈的触发源各不相同，也由调用点自配。
struct CheckToggleButton: View {
    /// 当前状态的 SF Symbol（切换时组件自动做 replace 过渡）
    let symbol: String
    let tint: Color
    var symbolSize: CGFloat = 24
    /// 视觉占位尺寸（影响布局）；命中区在此基础上自动外扩到至少 44×44，不改变布局
    var visualSize = CGSize(width: 44, height: 44)
    /// 命中区是否外扩到 44pt 保底。挨着其他可点内容、需要「只点方框本身才触发」
    /// 的场景（待办行的完成勾选，右侧紧贴点按进编辑的标题区）传 false，只认视觉框
    var expandsHitArea = true
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: symbolSize))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: visualSize.width, height: visualSize.height)
                .contentShape(expandsHitArea ? AnyShape(MinHitArea()) : AnyShape(Rectangle()))
        }
        .buttonStyle(PressableStyle(scale: 0.9))
        .accessibilityLabel(accessibilityLabel)
    }
}

/// 以视图中心为基准、外扩到至少 44×44 的命中区形状（HIG 最小触控目标）。
/// 视觉小于 44pt 的勾选框（如待办行的 36×26）靠它保证可点性，且不推挤布局。
private struct MinHitArea: Shape {
    func path(in rect: CGRect) -> Path {
        let w = max(rect.width, 44), h = max(rect.height, 44)
        return Path(CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
    }
}
