import XCTest
@testable import OmnyCore

/// 记账计算器：数字/小数点/运算符输入、乘除优先级、Decimal 精度、退格/清空。
final class ExpenseCalculatorTests: XCTestCase {

    private func calc(_ build: (inout ExpenseCalculator) -> Void) -> ExpenseCalculator {
        var c = ExpenseCalculator()
        build(&c)
        return c
    }

    // MARK: 基本输入

    func testInputDigits() {
        let c = calc { $0.input(digit: 1); $0.input(digit: 9) }
        XCTAssertEqual(c.currentValue, Decimal(string: "19"))
        XCTAssertEqual(c.displayValue, "19")
    }

    func testLeadingZeroReplaced() {
        // "0" 后输数字应替换而非变 "05"
        let c = calc { $0.input(digit: 0); $0.input(digit: 5) }
        XCTAssertEqual(c.displayValue, "5")
    }

    func testDot() {
        let c = calc { $0.input(digit: 1); $0.inputDot(); $0.input(digit: 5) }
        XCTAssertEqual(c.currentValue, Decimal(string: "1.5"))
    }

    func testDotOnEmptyBecomesZeroDot() {
        let c = calc { $0.inputDot(); $0.input(digit: 5) }
        XCTAssertEqual(c.currentValue, Decimal(string: "0.5"))
    }

    func testSingleDotOnly() {
        // 重复小数点被忽略
        let c = calc { $0.input(digit: 1); $0.inputDot(); $0.inputDot(); $0.input(digit: 5) }
        XCTAssertEqual(c.currentValue, Decimal(string: "1.5"))
    }

    // MARK: 加减

    func testAddition() {
        // 19 + 35 = 54（用户实测那两笔）
        let c = calc {
            $0.input(digit: 1); $0.input(digit: 9)
            $0.input(op: .add)
            $0.input(digit: 3); $0.input(digit: 5)
        }
        XCTAssertEqual(c.displayExpression, "19 + 35")
        XCTAssertEqual(c.currentValue, Decimal(string: "54"))
    }

    func testSubtraction() {
        let c = calc {
            $0.input(digit: 5); $0.input(digit: 0)
            $0.input(op: .sub)
            $0.input(digit: 8)
        }
        XCTAssertEqual(c.currentValue, Decimal(string: "42"))
    }

    // MARK: 乘除优先级

    func testMultiplyDividePrecedence() {
        // 1 + 2 × 3 = 7（先乘后加），不是 9
        let c = calc {
            $0.input(digit: 1); $0.input(op: .add)
            $0.input(digit: 2); $0.input(op: .mul)
            $0.input(digit: 3)
        }
        XCTAssertEqual(c.currentValue, Decimal(string: "7"))
    }

    func testDivision() {
        let c = calc {
            $0.input(digit: 1); $0.input(digit: 0); $0.input(digit: 0)
            $0.input(op: .div)
            $0.input(digit: 4)
        }
        XCTAssertEqual(c.currentValue, Decimal(string: "25"))
    }

    func testDivideByZeroIsNil() {
        let c = calc {
            $0.input(digit: 5); $0.input(op: .div); $0.input(digit: 0)
        }
        XCTAssertNil(c.currentValue)
    }

    // MARK: Decimal 精度（不能用 Double，0.1+0.2 问题）

    func testDecimalPrecision() {
        let c = calc {
            $0.inputDot(); $0.input(digit: 1)   // 0.1
            $0.input(op: .add)
            $0.inputDot(); $0.input(digit: 2)   // 0.2
        }
        XCTAssertEqual(c.currentValue, Decimal(string: "0.3"))
    }

    // MARK: 运算符边界

    func testTrailingOperatorIgnored() {
        // "19 +" 未输右操作数 → 求值用 19
        let c = calc {
            $0.input(digit: 1); $0.input(digit: 9); $0.input(op: .add)
        }
        XCTAssertEqual(c.currentValue, Decimal(string: "19"))
    }

    func testLeadingOperatorRejected() {
        // 不能以运算符开头
        let c = calc { $0.input(op: .add); $0.input(digit: 5) }
        XCTAssertEqual(c.currentValue, Decimal(string: "5"))
        XCTAssertFalse(c.hasPendingOperation)
    }

    func testConsecutiveOperatorReplaced() {
        // 连按运算符 → 替换最后一个：19 + × 3 → 19 × 3 = 57
        let c = calc {
            $0.input(digit: 1); $0.input(digit: 9)
            $0.input(op: .add); $0.input(op: .mul)
            $0.input(digit: 3)
        }
        XCTAssertEqual(c.currentValue, Decimal(string: "57"))
    }

    // MARK: evaluate 收敛

    func testEvaluateCollapses() {
        var c = calc {
            $0.input(digit: 1); $0.input(digit: 9)
            $0.input(op: .add)
            $0.input(digit: 3); $0.input(digit: 5)
        }
        XCTAssertTrue(c.hasPendingOperation)
        c.evaluate()
        XCTAssertFalse(c.hasPendingOperation)      // 结果态：UI 可据此触发保存
        XCTAssertEqual(c.currentValue, Decimal(string: "54"))
        XCTAssertEqual(c.displayValue, "54")
        // 结果态继续输运算符可接着算
        c.input(op: .add); c.input(digit: 6)
        XCTAssertEqual(c.currentValue, Decimal(string: "60"))
    }

    // MARK: 退格 / 清空

    func testDeleteDigit() {
        let c = calc {
            $0.input(digit: 1); $0.input(digit: 9); $0.deleteLast()
        }
        XCTAssertEqual(c.currentValue, Decimal(string: "1"))
    }

    func testDeleteOperatorThenNumber() {
        // "19 +" 退格删掉 + → 停在 19；再退格删 9
        var c = calc {
            $0.input(digit: 1); $0.input(digit: 9); $0.input(op: .add)
        }
        c.deleteLast()                              // 删 +
        XCTAssertEqual(c.currentValue, Decimal(string: "19"))
        c.deleteLast()                              // 删 9
        XCTAssertEqual(c.currentValue, Decimal(string: "1"))
    }

    func testClear() {
        var c = calc {
            $0.input(digit: 1); $0.input(op: .add); $0.input(digit: 2)
        }
        c.clear()
        XCTAssertNil(c.currentValue)
        XCTAssertEqual(c.displayExpression, "")
        XCTAssertEqual(c.displayValue, "0")
    }

    func testEmptyIsNil() {
        XCTAssertNil(ExpenseCalculator().currentValue)
    }
}
