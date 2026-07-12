import Foundation

/// 记账金额输入的计算器：支持 + − × ÷、连续运算、乘除优先级，金额用 Decimal 保精度。
///
/// 放 OmnyCore（纯逻辑无 UI 依赖）：便于 swift test 单测，也让金额精度规则集中一处。
/// 记账场景不需要括号/多级嵌套，故只做「一串 操作数 运算符 操作数 …」的线性表达式，
/// 求值时两趟：先算乘除、再算加减（保证 `1 + 2 × 3 = 7` 而非 9）。
///
/// 交互模型（供 UI 层驱动）：
/// - `input(digit:)` 追加数字，`inputDot()` 加小数点（每个操作数最多一个）
/// - `input(op:)` 追加运算符（连按运算符视为替换最后一个）
/// - `deleteLast()` 退格，`clear()` 清空
/// - `hasPendingOperation` 为 true 时按 = 应先 `evaluate()` 出结果；为 false（已是结果）时 UI 可据此触发保存
/// - `displayExpression` 给金额条显示算式，`currentValue` 是当前可入库的金额
public struct ExpenseCalculator: Equatable, Sendable {

    public enum Op: String, Equatable, Sendable {
        case add = "+", sub = "−", mul = "×", div = "÷"
    }

    /// 表达式记号：操作数（字符串保留用户输入形态，如 "19." 中间态）或运算符
    private enum Token: Equatable {
        case number(String)
        case op(Op)
    }

    private var tokens: [Token] = []
    /// 当前正在输入的操作数（未并入 tokens）；空串表示等待输入新操作数
    private var current: String = ""

    public init() {}

    // MARK: 输入

    /// 追加一位数字（"0"-"9"）
    public mutating func input(digit: Int) {
        guard (0...9).contains(digit) else { return }
        // 避免前导多余 0："0" 后再输数字应替换（除非已有小数点）
        if current == "0" { current = "" }
        current += String(digit)
    }

    /// 加小数点：每个操作数最多一个，且不与已有的重复
    public mutating func inputDot() {
        if current.isEmpty { current = "0" }
        guard !current.contains(".") else { return }
        current += "."
    }

    /// 追加运算符。若当前无操作数在输入：
    ///   - tokens 末尾是运算符 → 替换它（用户改主意）
    ///   - tokens 为空 → 忽略（不能以运算符开头）
    /// 否则先把 current 并入 tokens，再追加运算符。
    public mutating func input(op: Op) {
        if current.isEmpty {
            guard case .op = tokens.last else {
                if tokens.isEmpty { return }       // 空表达式不接受前导运算符
                tokens.append(.op(op)); return     // 末尾是数字，正常追加
            }
            tokens[tokens.count - 1] = .op(op)     // 连按运算符 → 替换
            return
        }
        commitCurrent()
        tokens.append(.op(op))
    }

    /// 退格：优先删当前输入的最后一位；当前为空则回退到上一个 token
    public mutating func deleteLast() {
        if !current.isEmpty {
            current.removeLast()
            return
        }
        guard let last = tokens.popLast() else { return }
        switch last {
        case .op:
            break                                   // 删掉运算符，停在前一个操作数（已在 tokens 里）
        case .number(let n):
            current = n                             // 把上一个操作数拉回可继续编辑
            if !current.isEmpty { current.removeLast() }
        }
    }

    public mutating func clear() {
        tokens.removeAll()
        current = ""
    }

    // MARK: 求值

    /// 是否有待完成的运算（存在运算符 → 按 = 应先算出结果）
    public var hasPendingOperation: Bool {
        tokens.contains { if case .op = $0 { return true } else { return false } }
    }

    /// 求值：把当前表达式算成一个结果，收敛成单一操作数。无有效表达式时保持不变。
    public mutating func evaluate() {
        guard let value = computedValue() else { return }
        tokens = []
        current = Self.format(value)
    }

    /// 当前可入库的金额（Decimal）。空/非法返回 nil。
    public var currentValue: Decimal? {
        computedValue()
    }

    /// 供 UI 金额条显示的算式串（如 "19 + 35"）；无内容时为空串
    public var displayExpression: String {
        var parts = tokens.map { token -> String in
            switch token {
            case .number(let n): return n
            case .op(let o): return o.rawValue
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts.joined(separator: " ")
    }

    /// 供大字显示的当前值（结果或正在输入的操作数）
    public var displayValue: String {
        if !current.isEmpty { return current }
        if case .number(let n)? = tokens.last { return n }
        return "0"
    }

    // MARK: 内部

    private mutating func commitCurrent() {
        guard !current.isEmpty else { return }
        // 规整中间态如 "19." → "19"
        tokens.append(.number(current))
        current = ""
    }

    /// 计算整串表达式的值。两趟：先乘除、后加减。
    private func computedValue() -> Decimal? {
        // 组装完整 token 序列（含未提交的 current）
        var all = tokens
        if !current.isEmpty { all.append(.number(current)) }
        // 末尾是运算符（如 "19 +"）→ 忽略末尾运算符，用前面的部分求值
        if case .op = all.last { all.removeLast() }
        guard !all.isEmpty else { return nil }

        // 拆成操作数数组 + 运算符数组
        var numbers: [Decimal] = []
        var ops: [Op] = []
        for token in all {
            switch token {
            case .number(let s):
                guard let d = Decimal(string: s) else { return nil }
                numbers.append(d)
            case .op(let o):
                ops.append(o)
            }
        }
        guard numbers.count == ops.count + 1 else { return nil }  // 结构必须是 n (op n)*

        // 第一趟：乘除
        var foldedNums = [numbers[0]]
        var foldedOps: [Op] = []
        for (i, op) in ops.enumerated() {
            let rhs = numbers[i + 1]
            switch op {
            case .mul:
                foldedNums[foldedNums.count - 1] *= rhs
            case .div:
                guard rhs != 0 else { return nil }   // 除零：非法，返回 nil
                foldedNums[foldedNums.count - 1] /= rhs
            case .add, .sub:
                foldedOps.append(op)
                foldedNums.append(rhs)
            }
        }
        // 第二趟：加减
        var result = foldedNums[0]
        for (i, op) in foldedOps.enumerated() {
            let rhs = foldedNums[i + 1]
            result += (op == .add) ? rhs : -rhs
        }
        return result
    }

    /// Decimal → 显示串：最多两位小数（钱），四舍五入；NSDecimalNumber.stringValue 天然去尾零
    /// （如 54.00 → "54"、1.50 → "1.5"），整数不显示 ".00"。
    /// public：App 层编辑记账时用它把已有金额还原成字符串逐位填回计算器。
    public static func format(_ value: Decimal) -> String {
        var v = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &v, 2, .plain)
        return (rounded as NSDecimalNumber).stringValue
    }
}
