import SwiftUI

/// 全屏图片查看器：黑底，捏合缩放（1x–4x 带橡皮筋）、双击放大/还原、放大后可拖拽平移。
/// 未放大时单击即关闭；放大后拖拽由本视图消费，未放大时不消费 drag，
/// 保留系统 zoom 转场的下拉交互式缩回。纯展示组件，只接收一张 Image。
struct ZoomableImageView: View {
    let image: Image
    @Environment(\.dismiss) private var dismiss

    /// 已落定的缩放倍率与平移量
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    /// 手势进行中的临时增量（结束时并入落定值）
    @GestureState private var gestureScale: CGFloat = 1
    @GestureState private var gestureOffset: CGSize = .zero

    private let minScale: CGFloat = 1
    private let maxScale: CGFloat = 4

    var body: some View {
        GeometryReader { _ in
            ZStack {
                Color.black.ignoresSafeArea()
                image
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(displayScale)
                    .offset(x: offset.width + gestureOffset.width,
                            y: offset.height + gestureOffset.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .contentShape(Rectangle())
            .gesture(magnify)
            // 只在放大后才挂拖拽手势：未放大时把 drag 留给系统的下拉缩回
            .gesture(scale > 1 ? pan : nil)
            .onTapGesture(count: 2) { toggleZoom() }
            .onTapGesture {
                // 未放大时单击关闭；放大态下单击不响应，避免误触退出
                if scale <= 1 { dismiss() }
            }
        }
        .statusBarHidden()
    }

    /// 渲染用倍率：手势中带橡皮筋（越界按比例衰减），松手后 clamp 回 [1, 4]
    private var displayScale: CGFloat {
        let raw = scale * gestureScale
        if raw < minScale { return minScale - (minScale - raw) * 0.5 }
        if raw > maxScale { return maxScale + (raw - maxScale) * 0.5 }
        return raw
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .updating($gestureScale) { value, state, _ in
                state = value.magnification
            }
            .onEnded { value in
                scale = min(max(scale * value.magnification, minScale), maxScale)
                if scale <= 1 {
                    withAnimation(.snappy) { offset = .zero; scale = 1 }
                }
            }
    }

    private var pan: some Gesture {
        DragGesture()
            .updating($gestureOffset) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                offset.width += value.translation.width
                offset.height += value.translation.height
            }
    }

    /// 双击：还原 ↔ 放大到 2.5x
    private func toggleZoom() {
        withAnimation(.snappy) {
            if scale > 1 {
                scale = 1; offset = .zero
            } else {
                scale = 2.5
            }
        }
    }
}
