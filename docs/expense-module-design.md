# 记账模块：架构说明 + 设计取舍

> 状态：**已实现并上线**（2026-07-11 拍板设计 → 2026-07-12 全链路完成，TestFlight build 19 已含正式记账页）。本文是记账模块的长期架构文档：数据契约、两级打标、去重策略等设计取舍仍然有效，改记账相关代码前先读本文与 `parsing-architecture.md`。文末「实现现状」记录已落地范围与仍待真机验证项。
> 定位：**捕获层 + 轻账本**。不做账户体系、预算、复式记账、报表。目标是把已有信息流（短信/识屏）里的消费自动沉淀成结构化条目，统一管理，后续做轻量统计。

## 一、总体思路：记账是第 6 类 `kind`，不是新系统

记账完全复用现有底座，**不新建实体、不新增入口通道**：

- **统一模型**：新增 `expense` 类型，字段挂到既有 `InboxItem`（扁平、可空共存），与快递/行程/待办/收藏并列。
- **解析管线**：沿用「分类靠正则、结构化靠 LLM」。银行短信「是不是消费」用正则判（关键词命中率高、可穷举）；「金额/商户/方向」交 LLM 抽（措辞变体不可穷举）；无 LLM 时正则降级。
- **入库通道**：仍走 `Ingestor` 唯一入口，新增 `ingestExpense`，带记账特有的**模糊去重**。
- **消费分类**：复用 `LLMTagClassifier` 的 enum-schema 思路（「只能从池里挑」），扩展为**两级分类**。

## 二、入口：1+2 复用现有通道，零新增入口代码

已确认现有两条通道的数据输入可直接复用，只需让解析层认得记账、让 `expense` 能落库：

| 入口 | 通道 | 需要改什么 |
|---|---|---|
| ① 银行动账短信 | 现有「解析文本」快捷指令 → `Ingestor.ingest(allowedTypes:)` | **把 `.expense` 加进白名单**（当前是 `[.package, .trip, .todo]`）。通道零改动 |
| ② 支付成功页截图 OCR | 现有识屏 → ScreenParser → `allowedTypes = nil` 全放行 | **不用动**，天然放行 `expense`；只要 ScreenParser/结构化解析能产出 `expense` 载荷 |
| ③ 微信/支付宝官方 CSV 导入 | —— | **本期不做**。作为后续增量：唯一含零钱/花呗的权威全量源，用官方交易单号做去重主键，吸收前两层重复。见下文「后续扩展」 |

> iOS 拿不到微信/支付宝实时支付数据是系统级限制，全行业无解，不追求 Android 式全自动。短信 + 截图已能覆盖大部分绑卡支付场景。

## 三、数据契约（一次性钉死维度，避免返工）

### OmnyCore — `Models.swift`

**`ItemType` 新增：**
```
case expense
```

**方向枚举（本期只支持支出/收入两类）：**
```swift
public enum ExpenseDirection: String, Codable, Sendable {
    case expense  // 支出
    case income   // 收入
    // 转账/理财赎回等暂不单列：识别不确定时标 needsReview，由用户人工归位或后续扩展
}
```

**`ExpenseInfo`（对齐 PackageInfo/TripInfo 风格）：**
```swift
public struct ExpenseInfo: Equatable, Sendable, Codable {
    public var direction: ExpenseDirection      // 支出/收入
    public var amount: Decimal?                 // 金额，必须 Decimal（钱的精度，禁用 Double）
    public var merchant: String?                // 商户/对方，如 "美团""星巴克"
    public var categoryMajor: String?           // 消费大类，如 "餐饮"（LLM 打标或用户改，入库时可空）
    public var categorySub: String?             // 消费细分，如 "午餐"
    public var occurredAt: DateComponents?       // 交易时间（沿用宽容日期解析，可能缺年/时区）
    public var channel: String?                 // 渠道/银行/支付平台，如 "招商银行""支付宝"
    public var cardTail: String?                // 卡尾号，如 "6789"，做去重主键之一
    public var txnID: String?                   // 官方交易单号，CSV 导入时的去重主键（短信/截图通常没有）
}
```

设计要点：
- **金额用 `Decimal`**，不用 `Double`。LLM 输出金额时用**字符串**（`"123.45"`），本地转 `Decimal(string:)`，避开 JSON 浮点精度问题。
- **两级分类拆成 `categoryMajor` + `categorySub` 两个字段**（不是一个 `[String]`），便于统计时按大类聚合、按细分下钻。
- `occurredAt` 用 `DateComponents?`，复用 `Ingestor.resolveDate` 的宽容补全（短信常缺年份）。

**`ParsedPayload` 新增：**
```
case expense(ExpenseInfo)
```
同步补 `itemType`（`case .expense: .expense`）与 `flattened`（`default` 分支已覆盖，无需改）。

### OmnyApp — `InboxItem.swift`

加一组可空的记账字段，与现有快递/行程字段并列：
```swift
// 记账
var expenseDirectionRaw: String?   // ExpenseDirection.rawValue
var amount: Decimal?               // SwiftData 支持 Decimal
var merchant: String?
var categoryMajor: String?
var categorySub: String?
var occurredAt: Date?
var channel: String?
var cardTail: String?
var txnID: String?
```
配套计算属性 `expenseDirection`（raw ↔ enum，参考现有 `packageStatus` 写法）。

> ⚠️ **契约影响**：`parsing-architecture.md` 明确 `ParsedPayload` 变更会波及 `Ingestor` 与视图层。新增 `case` 是加法式变更——各处 `switch` 会编译报错逼你补全，**不要用 `default` 糊过去**，逐个补全是有意为之的安全网。

## 四、解析层

### 1. 分类正则 — `RuleParser.classify`

新增 `expenseKeywords`，但要处理**优先级冲突**（「尾号」「元」会和快递短信撞）：

- **判定要求双命中**：`金额特征（¥ / 元 / 数字.数字两位小数）` + `交易动词（消费 / 支出 / 收入 / 入账 / 支付 / 到账 / 交易）`，而非单关键词命中，降低误判。
- **优先级**：放在 `package` 判定**之后**（快递短信偶尔带金额，但快递关键词更强、更该优先），`bookmark` 之前。
- 真实银行短信脱敏后进 `RealSMSTests` 做基线（项目规矩）。

### 2. 结构化 LLM — `LLMStructuredParser.parseExpense`

照 `parsePackage` 模板新增：system prompt + JSON Schema 各一份，让 LLM 抽 `direction / amount(字符串) / merchant / channel / cardTail / occurredAt(ISO8601)`。

- **不让 LLM 打分类**（categoryMajor/Sub）——分类交给下面独立的 categorizer 异步补（和收藏打标同构，顺序：先入库拿到金额/商户，再打标更准）。
- **抽取失败（金额为空）返回 nil**，交管线兜底/降级，不产「空账单卡」。参考 `parsePackage` 的 `hasAnyField` 守卫。
- 置信度：有金额 + 方向给高分（0.9）；只有零散字段给低分（0.6）→ 下游标 `needsReview`。

### 3. 正则降级 — `RuleParser.extractExpense`

无 LLM 时兜底。银行短信金额格式相对规整（`¥1,234.56` / `人民币100.00元` / `消费100元`），正则能抠出金额 + 卡尾号 + 方向（「支出/消费」vs「收入/到账」），够降级用，也做测试基线。**按契约「不删正则结构化」，此路径必须保留。**

## 五、消费分类：两级 enum-schema 打标

新增 `LLMExpenseCategorizer`（与 `LLMTagClassifier` 并列），核心设计：

- **分类池是两级结构**（设置页配置）：
  ```
  餐饮 → [早餐, 午餐, 晚餐, 外卖, 咖啡零食]
  交通 → [打车, 公交地铁, 加油, 停车]
  购物 → [日用, 服饰, 数码, 家居]
  ...
  ```
- **打标用扁平化 enum（方案 A，已选）**：把候选拍平成带分隔符的字符串 `"餐饮/午餐"`、`"交通/打车"` 作为 schema 的 `enum`，LLM 从中挑一个，本地按 `/` 拆回 `categoryMajor` + `categorySub`。
  - 好处：一次调用锁死**合法组合**，杜绝「大类餐饮 + 细分打车」的非法搭配；完全复刻现有 `LLMTagClassifier.claudeOutputSchema` 的 `enum: candidates` 机制，只是 candidates 换成拍平列表。
  - 放弃方案 B（两级动态 schema / 条件 schema）：Claude structured output 做条件依赖复杂、易触发降级重试，不划算。
- **异步补标，不阻塞入库**（同 `enrichBookmark` → `autoTag` 的模式）。

## 六、入库层 — `Ingestor.ingestExpense` 与去重

新增 `ingestExpense`，参考 `ingestPackage`，但**去重主键不同**：

- **有 `txnID`（CSV 导入）**：以官方交易单号为主键精确去重（权威、唯一）。本期虽不做 CSV，但字段和去重分支先留好。
- **无 `txnID`（短信/截图）**：模糊去重——`金额相等 + 时间窗（±N 分钟）+ 卡尾号/商户其一匹配` 视为同一笔，避免同一笔交易从短信和截图各进一次变两条。
- 入库后异步调 `LLMExpenseCategorizer` 补两级分类。
- 低置信度 / 方向不确定 → 标 `needsReview` 进「需处理」。

## 七、入口现状（设置页，正式记账页已就位，未占 tab）

按决策：**不动现有 5 tab 结构**，记账经设置页入口进入。已从最初的调试页升级为正式记账页：

- 设置页「记账」→ `ExpenseHomeView`（正式）：明细 / 日历 / 分析 三视图，共享月份切换 + FAB。另留「解析测试（调试）」→ `ExpenseDebugView`（粘贴短信解析入库 + expense 列表，调试用）。
- **手动记账**（`ExpenseEditView`，取代已删的 `ManualExpenseView`）：方向切换 + 分类宫格 + 自制计算器键盘（`ExpenseCalculator`）。走独立入库路径 `Ingestor.addManualExpense`：**尊重用户输入**——不走文本解析、不做模糊去重、不异步 LLM 覆盖分类（用户填了就是最终值，没填分类则留空）。列表行点击复用同表单编辑已有条目。
- 已跑通「文本 → 分类 → 结构化 → 打标 → 去重入库 → 展示」全链路。
- 正式的 tab 结构调整（TODO 里倾向「快递 + 行程合并腾位」给记账）仍待需求稳定后再做——**当前仍在设置页入口，未占正式 tab**。

## 八、实现现状（2026-07-12 全链路完成，build 19）

以下均已落地并测过（OmnyCore 部分单测全绿，App 部分 CI macOS job 编译通过）：

1. **OmnyCore 数据契约**：`ItemType.expense`、`ExpenseDirection`、`ExpenseInfo`、`ParsedPayload.expense`，各处 `switch` 已补全。
2. **解析能力**：`RuleParser.classify` 记账双命中判定 + `extractExpense` 正则降级；`LLMStructuredParser.parseExpense`（prompt + schema）；`ScreenParser` 第四类 expenses（识屏记账）；口语措辞（买/花/充值/收到/卖…）进 `expenseVerbs/incomeKeywords`。基线：`ExpenseParserTests` + `RealSMSTests`（脱敏银行短信）。
3. **消费分类**：`LLMExpenseCategorizer`（扁平化两级 enum-schema）+ `AppSettings` 两级分类池（JSON 存 UserDefaults）+ 设置页 `ExpenseCategoryManageView`。图标/颜色与分类池解耦（`Theme.ExpenseColor` + `ExpenseCategoryAppearance` 映射器，LLM 只用名字打标）。
4. **入库**：`InboxItem` 记账字段 + `expenseDirection`；`Ingestor.ingestExpense`（txnID 精确 / 金额+时间窗±10min+尾号或商户 模糊去重）+ 异步补分类；`addManualExpense`（尊重用户输入路径）；`.expense` 进「解析文本」白名单。
5. **正式记账页**：`Views/Expense/` 全套（`ExpenseHomeView`/明细/日历/分析 `DonutChart`/`ExpenseDetailView`/`ExpenseEditView` + 自制计算器键盘 `ExpenseCalculator`）；`ExpenseSupport`（格式化 + 聚合 + ExpenseRow）。

**仍待真机实测**（本机无法覆盖，装 TestFlight build 19 验）：① 环状图引线在分类多时是否拥挤；② 配 LLM Key 后真实抽取 + 打标准确率；③ 多渠道去重效果。另「确认记账」快捷指令可编辑弹窗真机起不来，见 `docs/confirm-expense-intent-handoff.md`（待 Mac 调试）。

**验证边界**（同 `parsing-architecture.md`）：OmnyCore 部分本机 `swift test` 可验证；App 部分靠 CI macOS job 编译；**LLM 真实抽取与打标效果本机无法测（无 Key），需在 App 里配 Key 实跑验证**。

## 九、后续扩展（本期不做，先留好扩展点）

- **CSV 账单导入**：微信/支付宝官方账单（唯一含零钱/花呗的权威全量源）。文件导入入口 + 固定列 CSV 解析器（格式固定，纯解析不用 LLM），以 `txnID` 为去重主键吸收短信/截图的重复条目。数据契约里的 `txnID` 字段已为此预留。
- **方向扩展**：转账/退款等，届时扩 `ExpenseDirection` 枚举（当前不确定的走 `needsReview`）。
- **轻量统计**：按 `categoryMajor` 聚合、按细分下钻的月度消费视图。两级分类字段已为此设计。
- **正式 UI 结构**：tab 合并腾位给记账，替换临时调试入口。
