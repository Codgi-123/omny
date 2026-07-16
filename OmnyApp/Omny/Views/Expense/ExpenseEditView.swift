import SwiftUI
import SwiftData
import OmnyCore

/// 添加 / 编辑记账。布局三段式：分类宫格（滚动区）→ 信息卡（金额+时间/备注+可展开字段，
/// 唯一一张卡）→ 计算器键盘（灰底白键黑符号，仅完成键带方向色）。
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
    @State private var note = ""
    @State private var merchant = ""
    @State private var channel = ""
    @State private var cardTail = ""
    @State private var showMore = false
    /// 时间选择展开（点信息卡的时间 chip 唤起）
    @State private var showTimePicker = false
    /// 文本框聚焦时收起底部自制计算器键盘，避免与系统键盘同框（备注/商户等文字输入）
    @FocusState private var textFieldFocused: Bool

    private var canSave: Bool { (calc.currentValue ?? 0) > 0 }
    /// 方向语义色：支出红 / 收入绿。金额、完成键随方向变色（记账 App 通行语义，一眼辨向）。
    private var directionTint: Color { direction == .income ? Theme.green : Theme.red }

    var body: some View {
        VStack(spacing: 0) {
            navRow
            // 滚动区只放分类宫格——金额/时间/备注全部收进底部信息卡，减少卡片种类
            ScrollView {
                ExpenseCategoryPickerGrid(major: $major, sub: $sub)
                    .padding(.vertical, 12)
                    .padding(.bottom, 16)
            }
            infoCard
            // 文本框聚焦（备注/商户等）时只收起计算器键盘，信息卡留在原位接系统键盘
            if !textFieldFocused {
                ExpenseKeypad(calc: $calc, direction: direction,
                              confirmTitle: "完成", confirmEnabled: canSave, onConfirm: save)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: textFieldFocused)
        .toolbar {
            // 系统键盘上方「完成」：让文本框失焦、收起系统键盘并唤回计算器
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { textFieldFocused = false }
            }
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

    // MARK: 信息卡（金额 + 时间/备注 + 可展开字段），键盘上方常驻的唯一一张卡

    private var infoCard: some View {
        VStack(spacing: 0) {
            // 金额行：左大金额（随方向红/绿），右小算式过程
            HStack(alignment: .firstTextBaseline) {
                Text(ExpenseFormat.amount(calc.currentValue ?? 0,
                                          direction: direction, signed: false))
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(directionTint)
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.2), value: calc.currentValue)
                    .lineLimit(1).minimumScaleFactor(0.5)
                Spacer()
                Text(calc.displayExpression)
                    .font(.footnote).foregroundStyle(Theme.sub).monospacedDigit()
                    .lineLimit(1)
            }
            .padding(.horizontal, Theme.Space.cardPad)
            .padding(.top, 12).padding(.bottom, 10)

            Divider().padding(.horizontal, Theme.Space.cardPad)

            // 时间 chip + 备注 + 展开更多
            HStack(spacing: 10) {
                Button {
                    withAnimation(.snappy) { showTimePicker.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        CategoryIconGlyph(icon: .asset("ExpIconClock"), pointSize: 14)
                        Text(timeChipText).monospacedDigit()
                    }
                    .font(.subheadline)
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Theme.fill, in: Capsule())
                }
                .buttonStyle(PressableStyle())

                TextField("点击填写备注", text: $note)
                    .focused($textFieldFocused)

                Button {
                    withAnimation(.snappy) { showMore.toggle() }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.sub)
                        .rotationEffect(.degrees(showMore ? 180 : 0))
                        .frame(width: 30, height: 30)
                        .background(Theme.fill, in: Circle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(showMore ? "收起更多信息" : "展开更多信息")
            }
            .padding(.horizontal, Theme.Space.cardPad)
            .padding(.vertical, 10)

            // 展开：时间选择
            if showTimePicker {
                Divider().padding(.horizontal, Theme.Space.cardPad)
                DatePicker("时间", selection: $occurredAt)
                    .padding(.horizontal, Theme.Space.cardPad)
                    .padding(.vertical, 8)
            }
            // 展开：商户/渠道/卡尾号
            if showMore {
                Divider().padding(.leading, Theme.Space.cardPad)
                fieldRow("商户", text: $merchant, placeholder: "选填")
                Divider().padding(.leading, Theme.Space.cardPad)
                fieldRow("渠道", text: $channel, placeholder: "如 支付宝、招商银行")
                Divider().padding(.leading, Theme.Space.cardPad)
                fieldRow("卡尾号", text: $cardTail, placeholder: "选填", keyboard: .numberPad)
            }
        }
        .background(Theme.card, in: .rect(cornerRadius: 16))
        .padding(.horizontal, 10)
    }

    /// 时间 chip 文案：今天只显示时刻，非今天带月日
    private var timeChipText: String {
        Calendar.current.isDateInToday(occurredAt)
            ? OmnyDateFormat.timeHM(occurredAt)
            : OmnyDateFormat.monthDayTime(occurredAt)
    }

    private func fieldRow(_ key: String, text: Binding<String>, placeholder: String,
                          keyboard: UIKeyboardType = .default) -> some View {
        HStack {
            Text(key).foregroundStyle(Theme.text)
            Spacer()
            TextField(placeholder, text: text)
                .keyboardType(keyboard)
                .focused($textFieldFocused)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(Theme.sub)
        }
        .padding(.horizontal, Theme.Space.cardPad)
        .padding(.vertical, 12)
    }

    // MARK: 加载 / 保存

    private func loadInitial() {
        if let item = editing {
            direction = item.expenseDirection
            major = item.categoryMajor ?? ""
            sub = item.categorySub ?? ""
            occurredAt = item.occurredAt ?? .now
            note = item.expenseNote ?? ""
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
        Ingestor.addManualExpense(info, occurredAt: occurredAt, note: clean(note),
                                  editing: editing, context: context)
        dismiss()
    }

    private func resetCategory() {
        // 切方向时清分类（支出/收入的分类池不同）
        major = ""; sub = ""
    }
}
