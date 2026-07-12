import SwiftUI
import SwiftData
import OmnyCore

/// 添加 / 编辑记账。功能按原型：分类为主角、时间常驻、其余字段折叠、底部自制计算器键盘。
/// 保存走 Ingestor.addManualExpense（尊重用户输入，不解析/不去重/不 LLM 覆盖）。
/// `editing` 非空为编辑回写，`defaultDate` 是新建时的默认时间（跟随当前所选月份）。
struct ExpenseEditView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    var editing: InboxItem?
    var defaultDate: Date = .now

    @State private var direction: ExpenseDirection = .expense
    @State private var calc = ExpenseCalculator()
    @State private var major = ""
    @State private var sub = ""
    @State private var occurredAt = Date()
    @State private var merchant = ""
    @State private var channel = ""
    @State private var cardTail = ""
    @State private var showMore = false

    private var majors: [String] { settings.expenseCategoryPool.keys.sorted() }
    private var subs: [String] { settings.expenseCategoryPool[major] ?? [] }
    private var canSave: Bool { (calc.currentValue ?? 0) > 0 }

    var body: some View {
        VStack(spacing: 0) {
            navRow
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    categorySection
                    if !major.isEmpty && !subs.isEmpty { subSection }
                    timeField
                    moreSection
                }
                .padding(.vertical, 12)
                .padding(.bottom, 20)
            }
            keyboardDock
        }
        .background(Theme.screen)
        .onAppear(perform: loadInitial)
    }

    // MARK: 顶部：取消 / 方向切换 / 保存（合并一行）

    private var navRow: some View {
        HStack {
            Button("取消") { dismiss() }
            Spacer()
            Picker("", selection: $direction) {
                Text("支出").tag(ExpenseDirection.expense)
                Text("收入").tag(ExpenseDirection.income)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .onChange(of: direction) { _, _ in resetCategory() }
            Spacer()
            Button("保存", action: save).fontWeight(.semibold).disabled(!canSave)
        }
        .padding(.horizontal, Theme.Space.page)
        .padding(.vertical, 12)
    }

    // MARK: 分类宫格（大类）

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("选择分类").font(.caption).foregroundStyle(Theme.sub)
                .padding(.horizontal, Theme.Space.page)
            let cols = Array(repeating: GridItem(.flexible(), spacing: 4), count: 5)
            LazyVGrid(columns: cols, spacing: 14) {
                ForEach(majors, id: \.self) { name in
                    categoryChip(name)
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private func categoryChip(_ name: String) -> some View {
        let ap = ExpenseCategoryAppearance.shared.appearance(major: name)
        let selected = major == name
        return Button {
            major = name
            if !subs.contains(sub) { sub = "" }
        } label: {
            VStack(spacing: 6) {
                IconChip(symbol: ap.symbol, color: ap.color, size: 48)
                    .overlay {
                        if selected {
                            RoundedRectangle(cornerRadius: 48 * 0.28 + 2, style: .continuous)
                                .strokeBorder(Theme.accent, lineWidth: 2.5)
                                .padding(-3)
                        }
                    }
                Text(name).font(.caption2).foregroundStyle(Theme.text)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: 细分（选中大类后展开）

    private var subSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(major) · 选择细分").font(.caption).foregroundStyle(Theme.sub)
                .padding(.horizontal, Theme.Space.page)
            let cols = Array(repeating: GridItem(.flexible(), spacing: 4), count: 5)
            LazyVGrid(columns: cols, spacing: 14) {
                ForEach(subs, id: \.self) { name in
                    subChip(name)
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 12)
        .background(Color(.tertiarySystemGroupedBackground),
                    in: .rect(cornerRadius: 14))
        .padding(.horizontal, Theme.Space.page)
    }

    private func subChip(_ name: String) -> some View {
        let ap = ExpenseCategoryAppearance.shared.appearance(major: major, sub: name)
        let selected = sub == name
        return Button {
            sub = (sub == name) ? "" : name
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(Theme.card).frame(width: 46, height: 46)
                        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
                    Image(systemName: ap.symbol)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(ap.color)
                }
                .overlay {
                    if selected {
                        Circle().strokeBorder(Theme.accent, lineWidth: 2.5)
                            .frame(width: 52, height: 52)
                    }
                }
                Text(name).font(.caption2).foregroundStyle(Theme.text)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: 时间（常驻，重要信息）

    private var timeField: some View {
        VStack(spacing: 0) {
            DatePicker("时间", selection: $occurredAt)
                .padding(.horizontal, Theme.Space.cardPad)
                .padding(.vertical, 8)
        }
        .background(Theme.card, in: .rect(cornerRadius: 14))
        .padding(.horizontal, Theme.Space.page)
    }

    // MARK: 更多信息（折叠：商户/渠道/卡尾号）

    private var moreSection: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.snappy) { showMore.toggle() }
            } label: {
                HStack {
                    Text("更多信息").foregroundStyle(Theme.text)
                    if !showMore {
                        Text("商户 · 渠道 · 卡尾号").font(.caption).foregroundStyle(Theme.sub)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.sub)
                        .rotationEffect(.degrees(showMore ? 90 : 0))
                }
                .padding(.horizontal, Theme.Space.cardPad)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showMore {
                Divider().padding(.leading, Theme.Space.cardPad)
                fieldRow("商户", text: $merchant, placeholder: "选填")
                Divider().padding(.leading, Theme.Space.cardPad)
                fieldRow("渠道", text: $channel, placeholder: "如 支付宝、招商银行")
                Divider().padding(.leading, Theme.Space.cardPad)
                fieldRow("卡尾号", text: $cardTail, placeholder: "选填", keyboard: .numberPad)
            }
        }
        .background(Theme.card, in: .rect(cornerRadius: 14))
        .padding(.horizontal, Theme.Space.page)
    }

    private func fieldRow(_ key: String, text: Binding<String>, placeholder: String,
                          keyboard: UIKeyboardType = .default) -> some View {
        HStack {
            Text(key).foregroundStyle(Theme.text)
            Spacer()
            TextField(placeholder, text: text)
                .keyboardType(keyboard)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(Theme.sub)
        }
        .padding(.horizontal, Theme.Space.cardPad)
        .padding(.vertical, 12)
    }

    // MARK: 底部计算器 dock（金额条 + 键盘）

    private var keyboardDock: some View {
        VStack(spacing: 0) {
            // 金额条：左算式、右结果
            HStack(alignment: .firstTextBaseline) {
                Text(calc.displayExpression)
                    .font(.footnote).foregroundStyle(Theme.sub).monospacedDigit()
                Spacer()
                Text(ExpenseFormat.amount(calc.currentValue ?? 0,
                                          direction: direction, signed: false))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(direction == .income ? Theme.green : Theme.text)
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
            .background(Color(.systemGray5))

            calculatorKeypad
        }
    }

    private var calculatorKeypad: some View {
        // 左侧数字区（3列4行）+ 右侧运算符列（÷×−）+ 底部 = 键
        HStack(spacing: 6) {
            VStack(spacing: 6) {
                keyRow(["7", "8", "9"])
                keyRow(["4", "5", "6"])
                keyRow(["1", "2", "3"])
                HStack(spacing: 6) {
                    numKey(".")
                    numKey("0")
                    funcKey("⌫") { calc.deleteLast() }
                }
            }
            VStack(spacing: 6) {
                opKey(.div)
                opKey(.mul)
                opKey(.sub)
                opKey(.add)
                // = / 完成：有待运算先算，已是结果再按即保存
                Button(action: equalsOrSave) {
                    Text(calc.hasPendingOperation ? "＝" : "完成")
                        .font(.title3.weight(.semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 54)
                        .background(Theme.accent, in: .rect(cornerRadius: 8))
                }
                .disabled(!calc.hasPendingOperation && !canSave)
            }
            .frame(width: 76)
        }
        .padding(6)
        .background(Color(.systemGray4))
    }

    private func keyRow(_ digits: [String]) -> some View {
        HStack(spacing: 6) { ForEach(digits, id: \.self) { numKey($0) } }
    }

    private func numKey(_ label: String) -> some View {
        Button {
            if label == "." { calc.inputDot() }
            else if let d = Int(label) { calc.input(digit: d) }
        } label: {
            Text(label).font(.title2)
                .frame(maxWidth: .infinity).frame(height: 54)
                .background(Theme.card, in: .rect(cornerRadius: 8))
                .foregroundStyle(Theme.text)
        }
    }

    private func funcKey(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.title3)
                .frame(maxWidth: .infinity).frame(height: 54)
                .background(Theme.card, in: .rect(cornerRadius: 8))
                .foregroundStyle(Theme.sub)
        }
    }

    private func opKey(_ op: ExpenseCalculator.Op) -> some View {
        Button { calc.input(op: op) } label: {
            Text(op.rawValue).font(.title2.weight(.medium))
                .frame(maxWidth: .infinity).frame(height: 54)
                .background(Theme.fill, in: .rect(cornerRadius: 8))
                .foregroundStyle(Theme.accent)
        }
    }

    private func equalsOrSave() {
        if calc.hasPendingOperation {
            calc.evaluate()
        } else {
            save()
        }
    }

    // MARK: 加载 / 保存

    private func loadInitial() {
        if let item = editing {
            direction = item.expenseDirection
            major = item.categoryMajor ?? ""
            sub = item.categorySub ?? ""
            occurredAt = item.occurredAt ?? .now
            merchant = item.merchant ?? ""
            channel = item.channel ?? ""
            cardTail = item.cardTail ?? ""
            showMore = !(merchant.isEmpty && channel.isEmpty && cardTail.isEmpty)
            // 金额预填进计算器（拆成一串数字输入）
            if let amount = item.amount {
                prefillAmount(amount)
            }
        } else {
            occurredAt = defaultDate
        }
    }

    /// 编辑态把已有金额填进计算器（逐位输入还原，含小数）
    private func prefillAmount(_ amount: Decimal) {
        let s = ExpenseCalculator.format(amount)
        for ch in s {
            if ch == "." { calc.inputDot() }
            else if let d = ch.wholeNumberValue { calc.input(digit: d) }
        }
    }

    private func save() {
        guard let amount = calc.currentValue, amount > 0 else { return }
        func clean(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        let info = ExpenseInfo(
            direction: direction, amount: amount,
            merchant: clean(merchant),
            categoryMajor: clean(major), categorySub: clean(sub),
            channel: clean(channel), cardTail: clean(cardTail))
        Ingestor.addManualExpense(info, occurredAt: occurredAt, editing: editing, context: context)
        dismiss()
    }

    private func resetCategory() {
        // 切方向时清分类（支出/收入的分类池不同）
        major = ""; sub = ""
    }
}
