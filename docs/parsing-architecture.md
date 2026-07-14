# 解析架构：分类靠正则，结构化靠 LLM

`OmnyCore` 把一段文本（短信、OCR 文字、分享内容）解析成结构化的 `InboxItem`。
核心分工：**判断"这是什么"用正则（廉价、可靠、可穷举），提取"具体内容"用 LLM（应对无穷的格式变体）**。

## 为什么这么分

- **分类是可穷举的**：一条短信是快递、行程、记账、待办还是收藏，靠关键词（"取件码""车次""消费+金额""http"）就能判得又快又准，不值得花 LLM。
- **结构化不可穷举**：同一类信息，不同厂家/驿站/航司/银行的短信措辞天差地别。正则模板追不完——每来一个新格式就要补一条正则，永远漏。这类"无法穷举的格式"正是 LLM 的用武之地。
- **收藏例外**：URL 是标准格式，正则一抠就准，不走 LLM（省钱）。
- **待办例外**：待办本就来自截图 OCR 的自由文本，天然只能靠 LLM 语义提取。
- **记账特例**：分类要求「金额特征 + 交易动词」**双命中**（单关键词易和快递短信的金额撞），判定放在快递/行程之后、收藏之前；结构化交 LLM（抽金额/商户/收支方向），但**消费分类不在这步做**——入库后由独立的 `LLMExpenseCategorizer` 异步补两级分类（同收藏打标的异步模式，先拿到金额/商户再打标更准）。

## 两个 LLM 入口：整段归一类 vs 一屏多类

- **短信 / 分享文本**走 `LLMStructuredParser`：整段文本归属**单一**类型（一条短信不会既是快递又是行程），`classify` 判类后交对应抽取。
- **截图 OCR** 走 `ScreenParser`：一屏脏文本常**同时含多条多类**（待办 + 快递 + 支付截图混在一起），它用一个 prompt 一次抽出 `{packages, trips, todos, expenses}` 四个数组，返回 `.mixed`，交 `Ingestor` 逐条落库。

## 数据流（短信 / 文本入口，LLMStructuredParser）

```
文本
 │
 ├─ RuleParser.classify()            ← 正则，判类型（关键词命中）
 │
 ├─ .package → LLM 抽快递字段 ────┐   carrier/单号/取件码/尾号/站点
 │             status 仍用正则 ───┤   （状态词可穷举，detectStatus 判得准）
 ├─ .trip    → LLM 抽行程字段 ────┤   车次或航班/时间/地点/座位
 ├─ .expense → LLM 抽记账字段 ────┤   金额(字符串→Decimal)/商户/收支/渠道/卡尾号/时间
 │             分类不在此步 ──────┤   （入库后 LLMExpenseCategorizer 异步补两级分类）
 ├─ .bookmark→ 正则抽 URL ────────┤   （标准格式，不花 LLM）
 └─ .todo/nil→ 返回 nil ──────────┘
                  │
                  └─ 落到 pipeline 的 fallback：LLMTodoParser 抽待办
                                                      │
                                              ParseResult → Ingestor 落库
```

## 关键类型与职责

| 文件 | 职责 |
|---|---|
| `Parser.swift` · `ParserPipeline` | 管线：primary 先解析，不达标/nil 落 fallback；LLM 挂了降级用规则结果 |
| `RuleParser.swift` | 正则引擎：`classify` 分类（仍在用）+ `extractPackage/extractTrip/extractExpense/extractBookmark/detectStatus`（结构化，保留作降级路径与测试基线，默认不再当 primary 结构化） |
| `LLM/LLMClient.swift` | LLM 调用共享底座：请求构造（claude/openai 协议分派）、发送、状态码校验、响应正文抽取、ISO 日期→DateComponents。所有 LLM 调用方共用 |
| `LLM/LLMStructuredParser.swift` | **分类靠正则 + 结构化靠 LLM** 的解析器，管线 primary。快递/行程/记账走 LLM，收藏走正则，待办交 fallback |
| `LLM/ScreenParser.swift` | 截图 OCR 专用：一屏多条多类一次抽四类数组，返回 `.mixed`（与短信入口的整段归一类互补） |
| `LLM/LLMTodoParser.swift` | 从自由文本抽待办，管线 fallback |
| `LLM/LLMExpenseCategorizer.swift` | 记账两级分类打标：大类/细分拍平成 `"餐饮/午餐"` 进 enum-schema，LLM 只能从用户配置的池里挑；入库后异步补，不阻塞落库 |

## 组装点

只有一处：`OmnyApp/Omny/Services/AppSettings.swift` 的 `parserPipeline`：
- 配了 LLM（设置页填了 Key）→ `primary = LLMStructuredParser`、`fallback = LLMTodoParser`。
- 没配 LLM → `primary = RuleParser()`，纯正则降级，保证无 Key/断网时仍可用（快递/行程/记账退回正则结构化：记账走 `extractExpense` 抠金额+卡尾号+方向）。

## 设计契约（改动的边界）

- **`ParseResult` / `ParsedPayload` / `PackageInfo` / `TripInfo` / `ExpenseInfo` 等数据类型稳定**——所以 `Ingestor` 和 App 视图层不受填充方式影响。无论谁来填充字段（正则还是 LLM），产出的 `ParseResult` 形状一致。新增类型（如 `expense`）走加法式扩展：给 `ParsedPayload` 加 `case` 会让各处 `switch` 编译报错逼你补全，**别用 `default` 糊过去**——逐个补全是有意为之的安全网。
- **正则结构化代码不删**：`extractPackage`/`extractTrip`/`extractExpense` 保留，是无 LLM 时的降级路径，也是 `RealSMSTests` 的测试基线。

## 踩过的坑

- **日期解析必须宽容**。行程时间字段让 LLM 输出 ISO8601，但 LLM 输出形态多变：可能缺年份（短信本就常不写年，`07-10T08:30`）、可能缺时区（`2026-07-10T08:30:00`）。标准 `ISO8601DateFormatter` 对这两种一律返回 `nil`，会**悄悄丢失行程时间**。`LLMClient.dateComponents(fromISO:)` 因此改为直接正则抽取年/月/日/时/分各部件：缺哪个部件就置 nil，天然契合 `DateComponents` 可选语义，缺的年份由 `Ingestor.resolveDate` 补。
  - 教训：mock 测试数据不要"太完美"。最初的 trip 测试 mock 都带完整年份+时区，掩盖了这个缺陷。补了缺年份/缺时区的用例防回归。

## 测试

- `LLMStructuredParserTests`：MockTransport 喂预置 LLM 响应，验证快递/行程/记账/收藏/待办各分派正确、status 来自正则、收藏与待办不发起 LLM 请求、缺年份/缺时区日期正确处理。
- `ScreenParserTests`：验证一屏多类混合文本抽成 `.mixed` 的多个数组。
- `ExpenseParserTests`：记账 `classify` 双命中判定 + `extractExpense` 正则降级；`RealSMSTests` 含脱敏银行短信基线。
- `RealSMSTests` / `RuleParserTests`：测 `RuleParser` 本身（正则能力），不走 LLM。
- 本机（Windows/WSL）只能测 `OmnyCore`；`OmnyApp` 的编译靠 CI 的 macOS job。
- LLM 结构化的**真实端到端效果**（对各种怪短信抽得准不准）本机无法测（无 API Key），需在 App 里配 Key 实跑验证。
