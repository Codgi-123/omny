import SwiftUI

// MARK: - 右下角悬浮新增按钮（FAB）

/// 右下角悬浮新增按钮：待办 / 收藏 / 记账统一的「+」入口（原在 Theme.swift，
/// 记账页曾有一份内联复制，收编到这里）。放在页面 overlay 的 bottomTrailing。
struct FloatingAddButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 27, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(Theme.accent.gradient, in: Circle())
                .shadow(color: Theme.accent.opacity(0.35), radius: 9, y: 4)
        }
        .buttonStyle(PressableStyle(scale: 0.94))
        .padding(.trailing, Theme.Space.page)
        .padding(.bottom, 18)
        .accessibilityLabel("新增")
    }
}
