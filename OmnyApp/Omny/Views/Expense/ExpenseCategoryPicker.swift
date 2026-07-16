import SwiftUI
import OmnyCore

/// 记账分类宫格（issue #24 的点亮式宫格抽成公共组件，issue #28 组件复用）：
/// 大类圆形灰底线稿，选中「点亮」蓝底白稿；配细分的大类带「…」角标，选中后细分就地展开在所在行下方。
/// 记一笔、账单详情改分类共用。`showManageEntry` 决定末尾是否带「设置」入口（进分类管理）。
struct ExpenseCategoryPickerGrid: View {
    @EnvironmentObject private var settings: AppSettings
    @Binding var major: String
    @Binding var sub: String
    var showManageEntry = true

    @State private var showCategoryManage = false

    private var majors: [String] { settings.expenseCategoryPool.keys.sorted() }
    private var subs: [String] { settings.expenseCategoryPool[major] ?? [] }

    /// 宫格单元：大类 或 末尾的「设置」入口
    private enum GridCell: Hashable {
        case major(String)
        case manage
    }

    /// 按每行 5 个切分宫格单元
    private var gridRows: [[GridCell]] {
        let cells: [GridCell] = majors.map { .major($0) } + (showManageEntry ? [.manage] : [])
        return stride(from: 0, to: cells.count, by: 5).map {
            Array(cells[$0..<min($0 + 5, cells.count)])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("选择分类").font(.caption).foregroundStyle(Theme.sub)
                .padding(.horizontal, Theme.Space.page)
            VStack(spacing: 14) {
                ForEach(Array(gridRows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 4) {
                        // 每个单元格都撑满等分宽度——整行时收缩居中、带补位的尾行又被撑开居左会对不齐
                        ForEach(row, id: \.self) { cell in
                            Group {
                                switch cell {
                                case .major(let name): categoryChip(name)
                                case .manage: manageChip
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        ForEach(0..<(5 - row.count), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity).frame(height: 1)
                        }
                    }
                    // 细分紧跟父类所在行展开
                    if row.contains(.major(major)), !subs.isEmpty {
                        subPanel
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
            .padding(.horizontal, 12)
        }
        .sheet(isPresented: $showCategoryManage) {
            NavigationStack {
                ExpenseCategoryManageView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showCategoryManage = false }
                        }
                    }
            }
        }
    }

    private func keyHaptic() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// 大类宫格项：圆形灰底 + 灰线稿，选中「点亮」蓝底白稿；配细分的大类右下角带「…」角标。
    private func categoryChip(_ name: String) -> some View {
        let ap = ExpenseCategoryAppearance.shared.appearance(major: name)
        let selected = major == name
        let hasSubs = !(settings.expenseCategoryPool[name] ?? []).isEmpty
        return Button {
            keyHaptic()
            withAnimation(.snappy(duration: 0.15)) {
                major = name
                if !subs.contains(sub) { sub = "" }
            }
        } label: {
            VStack(spacing: 6) {
                CategoryIconGlyph(icon: ap.icon, pointSize: 48 * 0.56)
                    .foregroundStyle(selected ? .white : Theme.sub)
                    .frame(width: 48, height: 48)
                    .background(selected ? AnyShapeStyle(Theme.accent.gradient)
                                         : AnyShapeStyle(Theme.fill),
                                in: Circle())
                    .overlay(alignment: .bottomTrailing) {
                        if hasSubs { subsBadge }
                    }
                Text(name)
                    .font(selected ? .caption2.weight(.semibold) : .caption2)
                    .foregroundStyle(Theme.text)
            }
        }
        .buttonStyle(PressableStyle())
    }

    private var subsBadge: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(Theme.sub)
            .frame(width: 15, height: 15)
            .background(Theme.card, in: Circle())
            .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
    }

    /// 宫格末尾的「设置」项：进分类管理
    private var manageChip: some View {
        Button {
            keyHaptic()
            showCategoryManage = true
        } label: {
            VStack(spacing: 6) {
                CategoryIconGlyph(icon: .asset("ExpIconSettings"), pointSize: 48 * 0.56)
                    .foregroundStyle(Theme.sub)
                    .frame(width: 48, height: 48)
                    .background(Theme.fill, in: Circle())
                Text("设置").font(.caption2).foregroundStyle(Theme.text)
            }
        }
        .buttonStyle(PressableStyle())
    }

    /// 细分面板：三级灰底圆角容器划出明显的「二级区域」
    private var subPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(major) · 细分").font(.caption2).foregroundStyle(Theme.sub)
                .padding(.horizontal, 8)
            let cols = Array(repeating: GridItem(.flexible(), spacing: 4), count: 5)
            LazyVGrid(columns: cols, spacing: 12) {
                ForEach(subs, id: \.self) { name in subChip(name) }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }

    private func subChip(_ name: String) -> some View {
        let ap = ExpenseCategoryAppearance.shared.appearance(major: major, sub: name)
        let selected = sub == name
        return Button {
            keyHaptic()
            withAnimation(.snappy(duration: 0.15)) {
                sub = (sub == name) ? "" : name
            }
        } label: {
            VStack(spacing: 6) {
                CategoryIconGlyph(icon: ap.icon, pointSize: 46 * 0.56)
                    .foregroundStyle(selected ? .white : Theme.sub)
                    .frame(width: 46, height: 46)
                    .background(selected ? AnyShapeStyle(Theme.accent.gradient)
                                         : AnyShapeStyle(Theme.card),
                                in: Circle())
                Text(name)
                    .font(selected ? .caption2.weight(.semibold) : .caption2)
                    .foregroundStyle(Theme.text)
            }
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - 分类选择弹窗（账单详情改分类 / 切换收支后重选类别）

/// 底部弹出的分类选择器：复用 ExpenseCategoryPickerGrid。确认后回传 (major, sub)。
/// 账单详情点分类改类型、切换收支后重选类别都用它（issue #28 四.1.1 / 四.2.1）。
struct CategoryPickerSheet: View {
    var direction: ExpenseDirection = .expense
    let initialMajor: String
    let initialSub: String
    var onDone: (_ major: String, _ sub: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var major = ""
    @State private var sub = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                ExpenseCategoryPickerGrid(major: $major, sub: $sub, showManageEntry: false)
                    .padding(.vertical, 16)
            }
            .background(Theme.screen)
            .navigationTitle(direction == .income ? "选择收入分类" : "选择支出分类")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { onDone(major, sub); dismiss() }
                        .fontWeight(.semibold).disabled(major.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { major = initialMajor; sub = initialSub }
    }
}
