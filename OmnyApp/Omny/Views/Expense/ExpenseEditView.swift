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
    /// 最近一次按运算符键输入的 op：驱动 +/× 单键循环（单数次+双数次×），
    /// 输入数字/退格/求值后清空重新计数
    @State private var lastOpTapped: ExpenseCalculator.Op?
    /// 分类编辑入口（宫格末尾「设置」项唤起）
    @State private var showCategoryManage = false
    /// 文本框聚焦时收起底部自制计算器键盘，避免与系统键盘同框（备注/商户等文字输入）
    @FocusState private var textFieldFocused: Bool

    private var majors: [String] { settings.expenseCategoryPool.keys.sorted() }
    private var subs: [String] { settings.expenseCategoryPool[major] ?? [] }
    private var canSave: Bool { (calc.currentValue ?? 0) > 0 }
    /// 方向语义色：支出红 / 收入绿。金额、完成键随方向变色（记账 App 通行语义，一眼辨向）。
    private var directionTint: Color { direction == .income ? Theme.green : Theme.red }

    var body: some View {
        VStack(spacing: 0) {
            navRow
            // 滚动区只放分类宫格——金额/时间/备注全部收进底部信息卡，减少卡片种类
            ScrollView {
                categorySection
                    .padding(.vertical, 12)
                    .padding(.bottom, 16)
            }
            infoCard
            // 文本框聚焦（备注/商户等）时只收起计算器键盘，信息卡留在原位接系统键盘
            if !textFieldFocused {
                calculatorKeypad
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
        .sheet(isPresented: $showCategoryManage) {
            // 记一笔现场就能改分类池（宫格末尾「设置」入口），改完回来宫格即时刷新
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

    // MARK: 分类宫格（大类，选中的大类若有细分就在其所在行下方就地展开）

    /// 宫格单元：大类 或 末尾的「设置」入口
    private enum GridCell: Hashable {
        case major(String)
        case manage
    }

    /// 按每行 5 个切分宫格单元
    private var gridRows: [[GridCell]] {
        let cells: [GridCell] = majors.map { .major($0) } + [.manage]
        return stride(from: 0, to: cells.count, by: 5).map {
            Array(cells[$0..<min($0 + 5, cells.count)])
        }
    }

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("选择分类").font(.caption).foregroundStyle(Theme.sub)
                .padding(.horizontal, Theme.Space.page)
            VStack(spacing: 14) {
                ForEach(Array(gridRows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 4) {
                        // 每个单元格都撑满等分宽度——否则整行时收缩居中、
                        // 带补位的尾行又被撑开居左，两种行对不齐
                        ForEach(row, id: \.self) { cell in
                            Group {
                                switch cell {
                                case .major(let name): categoryChip(name)
                                case .manage: manageChip
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        // 尾行补位，保证各行 5 列等宽对齐
                        ForEach(0..<(5 - row.count), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity).frame(height: 1)
                        }
                    }
                    // 细分紧跟父类所在行展开，而不是甩到页面底部
                    if row.contains(.major(major)), !subs.isEmpty {
                        subPanel
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
            .padding(.horizontal, 12)
        }
    }

    /// 大类宫格项：圆形灰底 + 灰线稿，选中「点亮」为系统蓝底 + 白线稿；
    /// 配有细分的大类在右下角带「…」角标提示可展开二级。
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

    /// 「…」角标：提示该大类选中后会展开细分
    private var subsBadge: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(Theme.sub)
            .frame(width: 15, height: 15)
            .background(Theme.card, in: Circle())
            .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
    }

    /// 宫格末尾的「设置」项：进分类管理，增删分类/改图标颜色
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

    // MARK: 细分面板（就地展开在父类所在行下方）

    /// 细分面板：三级灰底圆角容器划出明显的「二级区域」，标题点明所属大类。
    private var subPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(major) · 细分").font(.caption2).foregroundStyle(Theme.sub)
                .padding(.horizontal, 8)
            let cols = Array(repeating: GridItem(.flexible(), spacing: 4), count: 5)
            LazyVGrid(columns: cols, spacing: 12) {
                ForEach(subs, id: \.self) { name in
                    subChip(name)
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemGroupedBackground),
                    in: .rect(cornerRadius: 14))
    }

    /// 细分项：与大类同款圆形灰底线稿，选中蓝底白稿。
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

    // MARK: 计算器键盘（铺在页面灰底上：全白键 + 黑色符号，只有完成键带方向色）

    private var calculatorKeypad: some View {
        // 四等宽列：前三列数字（1-9 自上而下 + 底排 . 0 ⌫），第四列功能键
        // （+×、−÷ 单键循环 + 跨两排完成键），功能列与数字键同宽。
        HStack(alignment: .top, spacing: 8) {
            keyColumn(["1", "4", "7", "."])
            keyColumn(["2", "5", "8", "0"])
            VStack(spacing: 8) {
                numKey("3"); numKey("6"); numKey("9"); deleteKey
            }
            VStack(spacing: 8) {
                cycleOpKey(.add, .mul)
                cycleOpKey(.sub, .div)
                confirmKey
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private func keyColumn(_ labels: [String]) -> some View {
        VStack(spacing: 8) { ForEach(labels, id: \.self) { numKey($0) } }
    }

    /// 每次按键的触感反馈（用户明确要求全键震动；轻触档，保存键单独用中档）
    private func keyHaptic() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// 白色键面（数字/退格/运算符共用底）：白底大圆角 + 极浅阴影，铺在页面灰底上
    private func keyFace<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity).frame(height: 52)
            .background(Theme.card, in: .rect(cornerRadius: 14))
            .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
    }

    private func numKey(_ label: String) -> some View {
        Button {
            keyHaptic()
            lastOpTapped = nil        // 输入数字后运算符键重新从单数次计
            if label == "." { calc.inputDot() }
            else if let d = Int(label) { calc.input(digit: d) }
        } label: {
            keyFace {
                Text(label).font(.title2).foregroundStyle(Theme.text)
            }
        }
    }

    /// 退格键：点按删一位，长按清空整个算式（清空用更重的触感区分）
    private var deleteKey: some View {
        Button {
            keyHaptic()
            lastOpTapped = nil
            calc.deleteLast()
        } label: {
            keyFace {
                CategoryIconGlyph(icon: .asset("ExpIconBackspace"), pointSize: 23)
                    .foregroundStyle(Theme.text)
            }
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                lastOpTapped = nil
                withAnimation(.snappy(duration: 0.2)) { calc.clear() }
            }
        )
        .accessibilityLabel("删除一位，长按清空")
    }

    /// 循环运算符键：一个按钮两个符号（如「+ ×」），单数次按输入前者、双数次切换成后者
    /// （计算器对连按运算符是替换语义，正好承接）。当前生效的符号点亮为强调色。
    private func cycleOpKey(_ first: ExpenseCalculator.Op,
                            _ second: ExpenseCalculator.Op) -> some View {
        Button {
            keyHaptic()
            let next: ExpenseCalculator.Op = (lastOpTapped == first) ? second : first
            lastOpTapped = next
            calc.input(op: next)
        } label: {
            keyFace {
                HStack(spacing: 9) {
                    opSymbol(first)
                    opSymbol(second)
                }
            }
        }
        .accessibilityLabel("\(first.rawValue) 或 \(second.rawValue)，再按一次切换")
    }

    /// 循环键上的单个符号：当前生效的点亮为强调色，其余黑色
    private func opSymbol(_ op: ExpenseCalculator.Op) -> some View {
        Text(op.rawValue).font(.title3.weight(.medium))
            .foregroundStyle(lastOpTapped == op ? Theme.accent : Theme.text)
    }

    /// 完成键：跨两排高度、底色随方向红/绿。文案固定「完成」——算式没算完也直接
    /// 按整串表达式的结果入库（currentValue 本身就是全式求值），一按到底不用先按 =。
    private var confirmKey: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            save()
        } label: {
            Text("完成")
                .font(.title3.weight(.semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 52 * 2 + 8)
                .background(directionTint.gradient, in: .rect(cornerRadius: 14))
                .shadow(color: directionTint.opacity(0.25), radius: 3, y: 1)
        }
        .disabled(!canSave)
        .opacity(canSave ? 1 : 0.4)
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
