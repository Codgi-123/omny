import SwiftUI

// MARK: - 复制成功反馈

/// 「复制到剪贴板 + 成功态自动回退」的共享状态机（快递卡、紧凑快递卡、
/// 快递页「一键复制取件码」原本各自维护一份 copied + resetTask，收编到这里）。
/// copy(_:) 写入剪贴板并柔和切到「已复制」，1.5 秒后自动回退；
/// 重按前取消上一个回退任务，否则连点两次会让「已复制」提前消失。
/// 用法：视图里 `@State private var copyFeedback = CopyFeedback()`，
/// 展示态读 `copyFeedback.copied`，触感反馈仍由各调用点自配（轻触/成功不强行统一）。
@Observable
final class CopyFeedback {
    private(set) var copied = false
    private var resetTask: Task<Void, Never>?

    func copy(_ text: String) {
        UIPasteboard.general.string = text
        withAnimation(.snappy) { copied = true }
        resetTask?.cancel()
        resetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { withAnimation(.snappy) { copied = false } }
        }
    }
}
