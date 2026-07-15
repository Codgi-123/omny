import SwiftUI

// MARK: - 下拉刷新（防取消版）

extension View {
    /// 防取消的下拉刷新：包一层非结构化 Task——.refreshable 的任务绑定在刷新手势上，
    /// 视图刷新时会被 SwiftUI 取消并把取消传给 URLSession（表现为"同步失败：cancelled"）。
    /// Task {} 不继承外层取消，await .value 让菊花转到操作真正结束。
    /// 所有会随视图刷新的下拉刷新（滴答同步、航班动态）统一用这个，别直接用 .refreshable。
    func refreshableDetached(_ action: @escaping () async -> Void) -> some View {
        refreshable { await Task { await action() }.value }
    }
}
