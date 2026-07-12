import SwiftUI
import OmnyCore

/// 消费分类自定义：管理两级分类池（大类 → 细分）+ 每类的图标/颜色。
/// 写回 `AppSettings.expenseCategoryPool`（名字，供 LLM 打标）与
/// `ExpenseCategoryAppearance`（图标+色，纯展示）。二者解耦，见 ExpenseCategoryAppearance 注释。
struct ExpenseCategoryManageView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var editingMajor: MajorEdit?
    @State private var newMajor = ""

    /// 大类有序列表
    private var majors: [String] { settings.expenseCategoryPool.keys.sorted() }

    var body: some View {
        List {
            Section {
                ForEach(majors, id: \.self) { major in
                    NavigationLink {
                        SubcategoryListView(major: major)
                    } label: {
                        majorRow(major)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) { deleteMajor(major) } label: {
                            Label("删除", systemImage: "trash")
                        }
                        Button { editingMajor = MajorEdit(name: major) } label: {
                            Label("外观", systemImage: "paintpalette")
                        }.tint(Theme.accent)
                    }
                }
                addMajorRow
            } header: {
                Text("消费大类").textCase(nil)
            } footer: {
                Text("左滑删除 / 改图标颜色；点进去管理细分。分类名用于 AI 自动打标，图标颜色仅用于展示。")
            }

            Section {
                Button("恢复默认分类") { settings.expenseCategoryPool = AppSettings.defaultExpenseCategoryPool }
            }
        }
        .navigationTitle("消费分类")
        .sheet(item: $editingMajor) { edit in
            CategoryAppearanceSheet(name: edit.name, isMajor: true)
        }
    }

    private func majorRow(_ major: String) -> some View {
        let ap = ExpenseCategoryAppearance.shared.appearance(major: major)
        let count = settings.expenseCategoryPool[major]?.count ?? 0
        return HStack(spacing: 12) {
            IconChip(symbol: ap.symbol, color: ap.color)
            Text(major).font(.body)
            Spacer()
            Text("\(count) 细分").font(.caption).foregroundStyle(Theme.sub)
        }
    }

    private var addMajorRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle.fill").foregroundStyle(Theme.accent).font(.title2)
            TextField("新增大类…", text: $newMajor).onSubmit(addMajor)
            if !trimmedNewMajor.isEmpty {
                Button("添加", action: addMajor)
            }
        }
    }

    private var trimmedNewMajor: String { newMajor.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func addMajor() {
        let name = trimmedNewMajor
        guard !name.isEmpty, settings.expenseCategoryPool[name] == nil else { return }
        settings.expenseCategoryPool[name] = []
        newMajor = ""
    }

    private func deleteMajor(_ major: String) {
        settings.expenseCategoryPool.removeValue(forKey: major)
        ExpenseCategoryAppearance.shared.removeOverride(name: major)
    }

    private struct MajorEdit: Identifiable { let name: String; var id: String { name } }
}

// MARK: - 细分列表

private struct SubcategoryListView: View {
    @EnvironmentObject private var settings: AppSettings
    let major: String
    @State private var newSub = ""
    @State private var editingSub: SubEdit?

    private var subs: [String] { settings.expenseCategoryPool[major] ?? [] }

    var body: some View {
        List {
            Section {
                ForEach(subs, id: \.self) { sub in
                    HStack(spacing: 12) {
                        // 细分图标（颜色沿用大类色）
                        let symbol = ExpenseCategoryAppearance.shared.currentSymbol(major: major, sub: sub)
                        let color = ExpenseCategoryAppearance.shared.appearance(major: major).color
                        IconChip(symbol: symbol, color: color, size: 32)
                        Text(sub).font(.body)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) { deleteSub(sub) } label: {
                            Label("删除", systemImage: "trash")
                        }
                        Button { editingSub = SubEdit(name: sub) } label: {
                            Label("图标", systemImage: "app.badge")
                        }.tint(Theme.accent)
                    }
                }
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle.fill").foregroundStyle(Theme.accent).font(.title2)
                    TextField("新增细分…", text: $newSub).onSubmit(addSub)
                    if !trimmedNewSub.isEmpty { Button("添加", action: addSub) }
                }
            } footer: {
                Text("细分颜色沿用「\(major)」大类色，只单独配图标。")
            }
        }
        .navigationTitle(major)
        .sheet(item: $editingSub) { edit in
            CategoryAppearanceSheet(name: edit.name, isMajor: false, majorColorKey: nil)
        }
    }

    private var trimmedNewSub: String { newSub.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func addSub() {
        let name = trimmedNewSub
        guard !name.isEmpty else { return }
        var list = settings.expenseCategoryPool[major] ?? []
        guard !list.contains(name) else { return }
        list.append(name)
        settings.expenseCategoryPool[major] = list
        newSub = ""
    }

    private func deleteSub(_ sub: String) {
        var list = settings.expenseCategoryPool[major] ?? []
        list.removeAll { $0 == sub }
        settings.expenseCategoryPool[major] = list
        ExpenseCategoryAppearance.shared.removeOverride(name: sub)
    }

    private struct SubEdit: Identifiable { let name: String; var id: String { name } }
}

// MARK: - 图标 + 颜色选择 sheet

/// 给某分类名选图标（精选 SF Symbol 网格）+ 颜色（签名色板，仅大类可选）。
/// 保存写入 ExpenseCategoryAppearance 用户覆盖。
private struct CategoryAppearanceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let name: String
    let isMajor: Bool
    var majorColorKey: String? = nil

    @State private var selectedSymbol = ""
    @State private var selectedColorKey = "food"

    private var previewColor: Color {
        Theme.ExpenseColor.color(forKey: selectedColorKey) ?? Theme.ExpenseColor.other
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // 预览
                    IconChip(symbol: selectedSymbol.isEmpty ? "tag.fill" : selectedSymbol,
                             color: previewColor, size: 64)
                        .padding(.top, 8)
                    Text(name).font(.headline)

                    // 颜色（仅大类可选；细分沿用大类色）
                    if isMajor {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("颜色").font(.caption).foregroundStyle(Theme.sub)
                            HStack(spacing: 12) {
                                ForEach(Theme.ExpenseColor.keys, id: \.self) { key in
                                    let c = Theme.ExpenseColor.color(forKey: key) ?? Theme.ExpenseColor.other
                                    Circle().fill(c).frame(width: 30, height: 30)
                                        .overlay {
                                            if key == selectedColorKey {
                                                Circle().strokeBorder(Theme.accent, lineWidth: 3).padding(-3)
                                            }
                                        }
                                        .onTapGesture { selectedColorKey = key }
                                }
                            }
                        }
                        .padding(.horizontal)
                    }

                    // 图标网格
                    VStack(alignment: .leading, spacing: 8) {
                        Text("图标").font(.caption).foregroundStyle(Theme.sub)
                        let cols = Array(repeating: GridItem(.flexible(), spacing: 10), count: 6)
                        LazyVGrid(columns: cols, spacing: 12) {
                            ForEach(ExpenseCategoryAppearance.pickerSymbols, id: \.self) { sym in
                                Image(systemName: sym)
                                    .font(.system(size: 20))
                                    .foregroundStyle(sym == selectedSymbol ? .white : Theme.text)
                                    .frame(width: 44, height: 44)
                                    .background(sym == selectedSymbol ? previewColor : Theme.card,
                                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .onTapGesture { selectedSymbol = sym }
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.bottom, 20)
            }
            .background(Theme.screen)
            .navigationTitle("\(name) 外观")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(selectedSymbol.isEmpty)
                }
            }
            .onAppear(perform: loadCurrent)
        }
    }

    private func loadCurrent() {
        // 回显当前生效的图标；大类同时回显颜色（从当前 appearance 反推 key）
        selectedSymbol = ExpenseCategoryAppearance.shared
            .currentSymbol(major: isMajor ? name : nil, sub: isMajor ? nil : name)
        if isMajor {
            let cur = ExpenseCategoryAppearance.shared.appearance(major: name).color
            selectedColorKey = Theme.ExpenseColor.keys.first {
                Theme.ExpenseColor.color(forKey: $0) == cur
            } ?? "food"
        }
    }

    private func save() {
        // 细分不改颜色：存 symbol，colorKey 传空（渲染时颜色取自大类）
        ExpenseCategoryAppearance.shared.setOverride(
            name: name, symbol: selectedSymbol,
            colorKey: isMajor ? selectedColorKey : "")
        dismiss()
    }
}
