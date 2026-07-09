# 解析架构：分类靠正则，结构化靠 LLM

`OmnyCore` 把一段文本（短信、OCR 文字、分享内容）解析成结构化的 `InboxItem`。
核心分工：**判断"这是什么"用正则（廉价、可靠、可穷举），提取"具体内容"用 LLM（应对无穷的格式变体）**。

## 为什么这么分

- **分类是可穷举的**：一条短信是快递、行程、待办还是收藏，靠关键词（"取件码""车次""http"）就能判得又快又准，不值得花 LLM。
- **结构化不可穷举**：同一类信息，不同厂家/驿站/航司的短信措辞天差地别。正则模板追不完——每来一个新格式就要补一条正则，永远漏。这类"无法穷举的格式"正是 LLM 的用武之地。
- **收藏例外**：URL 是标准格式，正则一抠就准，不走 LLM（省钱）。
- **待办例外**：待办本就来自截图 OCR 的自由文本，天然只能靠 LLM 语义提取。

## 数据流

```
文本
 │
 ├─ RuleParser.classify()            ← 正则，判类型（关键词命中）
 │
 ├─ .package → LLM 抽快递字段 ────┐   carrier/单号/取件码/尾号/站点
 │             status 仍用正则 ───┤   （状态词可穷举，detectStatus 判得准）
 ├─ .trip    → LLM 抽行程字段 ────┤   车次或航班/时间/地点/座位
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
| `RuleParser.swift` | 正则引擎：`classify` 分类（仍在用）+ `extractPackage/extractTrip/extractBookmark/detectStatus`（结构化，保留作降级路径与测试基线，默认不再当 primary 结构化） |
| `LLM/LLMClient.swift` | LLM 调用共享底座：请求构造（claude/openai 协议分派）、发送、状态码校验、响应正文抽取、ISO 日期→DateComponents。两个 LLM parser 共用 |
| `LLM/LLMStructuredParser.swift` | **分类靠正则 + 结构化靠 LLM** 的解析器，管线 primary。快递/行程走 LLM，收藏走正则，待办交 fallback |
| `LLM/LLMTodoParser.swift` | 从自由文本抽待办，管线 fallback |

## 组装点

只有一处：`OmnyApp/Omny/Services/AppSettings.swift` 的 `parserPipeline`：
- 配了 LLM（设置页填了 Key）→ `primary = LLMStructuredParser`、`fallback = LLMTodoParser`。
- 没配 LLM → `primary = RuleParser()`，纯正则降级，保证无 Key/断网时仍可用（快递/行程退回正则结构化）。

## 设计契约（改动的边界）

- **`ParseResult` / `ParsedPayload` / `PackageInfo` / `TripInfo` 等数据类型不变**——所以 `Ingestor` 和 App 视图层零改动。无论谁来填充字段（正则还是 LLM），产出的 `ParseResult` 形状一致。
- **正则结构化代码不删**：`extractPackage`/`extractTrip` 保留，是无 LLM 时的降级路径，也是 `RealSMSTests` 的测试基线。

## 踩过的坑

- **日期解析必须宽容**。行程时间字段让 LLM 输出 ISO8601，但 LLM 输出形态多变：可能缺年份（短信本就常不写年，`07-10T08:30`）、可能缺时区（`2026-07-10T08:30:00`）。标准 `ISO8601DateFormatter` 对这两种一律返回 `nil`，会**悄悄丢失行程时间**。`LLMClient.dateComponents(fromISO:)` 因此改为直接正则抽取年/月/日/时/分各部件：缺哪个部件就置 nil，天然契合 `DateComponents` 可选语义，缺的年份由 `Ingestor.resolveDate` 补。
  - 教训：mock 测试数据不要"太完美"。最初的 trip 测试 mock 都带完整年份+时区，掩盖了这个缺陷。补了缺年份/缺时区的用例防回归。

## 测试

- `LLMStructuredParserTests`：MockTransport 喂预置 LLM 响应，验证快递/行程/收藏/待办各分派正确、status 来自正则、收藏与待办不发起 LLM 请求、缺年份/缺时区日期正确处理。
- `RealSMSTests` / `RuleParserTests`：测 `RuleParser` 本身（正则能力），不走 LLM。
- 本机（Windows/WSL）只能测 `OmnyCore`；`OmnyApp` 的编译靠 CI 的 macOS job。
- LLM 结构化的**真实端到端效果**（对各种怪短信抽得准不准）本机无法测（无 API Key），需在 App 里配 Key 实跑验证。
