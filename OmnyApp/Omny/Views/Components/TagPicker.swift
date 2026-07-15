import SwiftUI

// MARK: - 候选池 chip（单个胶囊）

/// 标签/分类候选池的胶囊 chip：选中 accent 底白字，未选卡面底普通字。
/// 收藏「添加收藏 / 收藏详情」的多选 chip 与筛选栏的单选 chip 原本各自复制，收编到这里。
/// `filterStyle` 表达筛选栏的刻意差异：内边距更大、选中态加粗（多选 chip 不变粗）。
struct SelectableChip: View {
    let label: String
    let selected: Bool
    /// 收藏筛选栏样式：14/7 内边距 + 选中加粗；默认是多选标签的紧凑样式（12/6、不变粗）
    var filterStyle = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline)
                .fontWeight(filterStyle ? (selected ? .semibold : .regular) : nil)
                .foregroundStyle(selected ? .white : Theme.text)
                .padding(.horizontal, filterStyle ? 14 : 12)
                .padding(.vertical, filterStyle ? 7 : 6)
                .background(selected ? Theme.accent : Theme.card, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 标签多选（流式排布）

/// 标签多选：候选池平铺成流式 chip，点选切换；保留点选顺序（后选的追加在末尾）。
/// 业务上「候选池怎么合并出来」由调用方提供（见 AppSettings.mergedTagCandidates）。
struct TagPicker: View {
    let candidates: [String]
    @Binding var selection: [String]

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(candidates, id: \.self) { tag in
                let on = selection.contains(tag)
                SelectableChip(label: tag, selected: on) {
                    if on { selection.removeAll { $0 == tag } }
                    else { selection.append(tag) }
                }
            }
        }
    }
}

// MARK: - 流式布局

/// 简易流式布局：标签胶囊按宽度自动换行（iOS 16+ Layout 协议）。
/// 原在 ListViews.swift，随 chip 组件一起收进 Components。
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
