import SwiftUI
import OmnyCore

/// 记账计算器键盘（issue #24 的自制键盘抽成公共组件，issue #28 组件复用）：
/// 四等宽列——前三列数字（1-9 + 底排 . 0 ⌫），第四列 +×/−÷ 单键循环 + 跨两排完成键。
/// 全白键黑符号，仅完成键随方向红/绿。记一笔、账单详情改金额共用。
///
/// 完成键文案固定 `confirmTitle`——算式没算完也直接按整串表达式结果（currentValue 本身
/// 就是全式求值），一按到底不用先按 =。`confirmEnabled` 为假时置灰。
struct ExpenseKeypad: View {
    @Binding var calc: ExpenseCalculator
    var direction: ExpenseDirection = .expense
    var confirmTitle: String = "完成"
    var confirmEnabled: Bool = true
    var onConfirm: () -> Void

    /// 最近一次按运算符键输入的 op：驱动 +/× 单键循环（单数次+双数次×），输入数字/退格后清空重新计数
    @State private var lastOpTapped: ExpenseCalculator.Op?

    /// 方向语义色：支出红 / 收入绿
    private var tint: Color { direction == .income ? Theme.green : Theme.red }

    var body: some View {
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

    private func keyHaptic() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// 白色键面：白底大圆角 + 极浅阴影，铺在页面灰底上
    private func keyFace<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity).frame(height: 52)
            .background(Theme.card, in: .rect(cornerRadius: 14))
            .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
    }

    private func numKey(_ label: String) -> some View {
        Button {
            keyHaptic()
            lastOpTapped = nil
            if label == "." { calc.inputDot() }
            else if let d = Int(label) { calc.input(digit: d) }
        } label: {
            keyFace { Text(label).font(.title2).foregroundStyle(Theme.text) }
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

    /// 循环运算符键：一个按钮两个符号（如「+ ×」），单数次按输入前者、双数次切换后者
    private func cycleOpKey(_ first: ExpenseCalculator.Op,
                            _ second: ExpenseCalculator.Op) -> some View {
        Button {
            keyHaptic()
            let next: ExpenseCalculator.Op = (lastOpTapped == first) ? second : first
            lastOpTapped = next
            calc.input(op: next)
        } label: {
            keyFace {
                HStack(spacing: 9) { opSymbol(first); opSymbol(second) }
            }
        }
        .accessibilityLabel("\(first.rawValue) 或 \(second.rawValue)，再按一次切换")
    }

    private func opSymbol(_ op: ExpenseCalculator.Op) -> some View {
        Text(op.rawValue).font(.title3.weight(.medium))
            .foregroundStyle(lastOpTapped == op ? Theme.accent : Theme.text)
    }

    /// 完成键：跨两排高度、底色随方向红/绿
    private var confirmKey: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onConfirm()
        } label: {
            Text(confirmTitle)
                .font(.title3.weight(.semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 52 * 2 + 8)
                .background(tint.gradient, in: .rect(cornerRadius: 14))
                .shadow(color: tint.opacity(0.25), radius: 3, y: 1)
        }
        .disabled(!confirmEnabled)
        .opacity(confirmEnabled ? 1 : 0.4)
    }
}

// MARK: - 金额编辑弹窗（账单详情「金额」行点击弹出）

/// 只改金额的底部弹窗：复用 ExpenseKeypad。确认后把新金额回传 `onDone`（issue #28 四.2.3）。
struct AmountEditorSheet: View {
    let initialAmount: Decimal
    var direction: ExpenseDirection = .expense
    var onDone: (Decimal) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var calc = ExpenseCalculator()

    private var canSave: Bool { (calc.currentValue ?? 0) > 0 }
    private var tint: Color { direction == .income ? Theme.green : Theme.red }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Text("修改金额").font(.headline)
                Spacer()
                Button("完成") { commit() }.fontWeight(.semibold).disabled(!canSave)
            }
            .padding(.horizontal, Theme.Space.page)
            .padding(.vertical, 14)

            // 金额大字预览
            Text(ExpenseFormat.amount(calc.currentValue ?? 0, direction: direction, signed: false))
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.2), value: calc.currentValue)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)

            Spacer(minLength: 0)

            ExpenseKeypad(calc: $calc, direction: direction,
                          confirmTitle: "完成", confirmEnabled: canSave) { commit() }
        }
        .background(Theme.screen)
        .presentationDetents([.height(480)])
        .onAppear {
            // 已有金额逐位填回计算器（含小数），与 ExpenseEditView 一致
            let s = ExpenseCalculator.format(initialAmount)
            for ch in s {
                if ch == "." { calc.inputDot() }
                else if let d = ch.wholeNumberValue { calc.input(digit: d) }
            }
        }
    }

    private func commit() {
        guard let amount = calc.currentValue, amount > 0 else { return }
        onDone(amount)
        dismiss()
    }
}
