# 交接：「确认记账」快捷指令弹窗不出现 — 待 Mac 调试

> 面向接手的 Mac 开发者。Windows 协作者已把逻辑写完、CI 编译通过、并用 WSL+真实 LLM
> 验证了解析与补分类逻辑正确，但**真机上「确认记账」的可编辑弹窗起不来**。差最后的
> 真机 App Intents 调试，只有 Mac + 真机能做。本文给全上下文和调试方向，避免你从零摸索。
> （commit 962627b 时的状态。设计定稿 `confirm-intent-io.md` 与 LLM 验证脚手架
> `llm-parse-test/` 在 Windows 协作者本地的 `.design-preview/`，未入库，如需可索取。）

## 一句话问题
「屏幕识别（关直接入库）→ 确认记账」链路：屏幕识别能解析出数据、能把实体传给确认记账
（实机打印实体摘要为「支出220.25元（牛肉面）」，说明**数据没丢**），但**确认记账的可编辑
确认弹窗没有正常出现**，最终走到「没有记账」。

---

## 背景与设计意图（为什么这么设计）

Omny 把快捷指令原子化：解析与入库分离，用户在快捷指令里自由编排是否加「确认」步骤。
- 「屏幕识别」`RecognizeTodoIntent`、「解析文本」`ParseTextIntent`：加了 `直接入库` 开关
  （默认开=原行为直接入库；关=只解析不入库，输出 `[InboxItemEntity]` 给下游）。
- 「确认记账」`ConfirmExpenseIntent`：接收 `[InboxItemEntity]`，**记账逐笔弹可编辑列表核对**，
  非记账（快递/行程/待办）静默入库。

**确认弹窗刻意不用 SnippetIntent**（那是 iOS 26，本项目部署目标 iOS 18 要兼容）。改用
**参数请求循环**（钱迹 iOS 16+ 的做法）：`perform()` 里 `while` 循环，每轮对工作参数调
`$choice.requestDisambiguation(among: [字段列表])` 弹出选择列表；点字段→再 requestValue/
requestDisambiguation 改→回循环顶重弹（值已更新）；点「✅确认」入库、「❌取消」跳过。
理论上 `requestDisambiguation` 是 iOS 16 API，不进 App、离线可用。

相关文件：
- `OmnyApp/Omny/Intents/InboxItemEntity.swift` — Intent 间传数据的 AppEntity
- `OmnyApp/Omny/Intents/OmnyIntents.swift` — ParseTextIntent / RecognizeTodoIntent（含 `直接入库` 开关、`parseToEntities`）
- `OmnyApp/Omny/Intents/ExpenseConfirmIntent.swift` — 确认记账（`perform` + `confirmOne` 循环 + `pickTime`）
- `OmnyApp/Omny/Services/Ingestor.swift` — `ingestParsed(payloads:)` public 入口（确认后入库复用去重/合并）

设计定稿见 `.design-preview/confirm-intent-io.md`（同目录，未入库）。

---

## 已验证 OK 的部分（不用再查）

1. **解析 + 补分类逻辑正确**。用 WSL + 真实 LLM 跑过独立测试（`.design-preview/llm-parse-test/`，
   独立 SwiftPM 包依赖本地 OmnyCore）。对「昨天午饭吃的牛肉面，花了220.25元」：
   - ScreenParser 抽出 direction=expense、amount=220.25、occurredAt=昨天、merchant=nil
     （口语句无独立商户名，LLM 判 nil 合理）。
   - 用 rawText 喂 `LLMExpenseCategorizer` 能补出「餐饮/午餐」。
2. **CI macOS 编译通过**（GitHub Actions app-macos job，最新 commit 962627b 绿）。
3. **实体传值不丢数据**。实机打印实体摘要为「支出220.25元（牛肉面）」，金额+商户都在。

## 一手实机现象（Windows 协作者亲测，关键证据）

- 第一次测：确认时弹窗显示一个叫「条目」、无值的界面，关闭后「没有记账」。
  （"条目"是 `ConfirmExpenseIntent` 的 `items` 参数 title —— 系统在跟用户要这个参数的值。）
- 加了 `@Property`/JSON 传值加固后再测：能打印出实体摘要「支出220.25元（牛肉面）」，
  说明数据到了，但**确认弹窗仍起不来，条目仍为空，仍「没有记账」**。
- 协作者主观判断：**「感觉是弹窗渲染有问题，导致无法渲染出弹窗」**。

---

## 根因假设（按可能性排序，供 Mac 调试时逐一排除）

### 假设 A（最可能）：`[InboxItemEntity]` 作为 @Parameter 跨动作传递未落到 items
现象「系统弹窗反问『条目』」强烈指向：**上游输出的实体没有真正绑定到 `ConfirmExpenseIntent.items`**。
可能原因：
- **AppEntity 数组作为 Intent 输入参数，快捷指令连线后系统仍视为"需要 resolve"**，而
  `InboxItemEntityQuery` 的 `entities(for:)`/`suggestedEntities()` **返回空数组** ——
  系统可能按 id 用 defaultQuery 重新 resolve 实体，查空 → items 变空 → 弹窗要参数。
  这是 AppEntity 瞬态传递的经典坑：**AppEntity 设计给"可查询的持久实体"，不适合瞬态传递**。
- 若如此，`@Property`/JSON 加固**治标不治本**——数据在实体里，但实体本身被 query 重查丢了。

**验证**：在 `perform()` 第一行加 `print("items.count=\(items.count)")`（或用 os_log）。
- 若 `items.count == 0` → 确认是传递/resolve 问题，走假设 A 的修法。
- 若 `items.count > 0` 但弹窗不出 → 走假设 B。

**假设 A 的候选修法**（Mac 上试）：
1. 让 `InboxItemEntityQuery.entities(for:)` 真正能按 id 返回实体 —— 需要一个进程内
   注册表（static dict）存放解析时产出的实体，query 从里面查。这样系统重 resolve 能查到。
2. 或改传递载体：不用 `[InboxItemEntity]`，改用 **`[String]`（每个是 Payload JSON）** 作为
   Intent 输入参数（String 数组是最稳的可传类型，无 resolve 问题），确认记账内部解码。
   代价：快捷指令里看到的是 JSON 字符串数组，不如实体直观，但传递绝对可靠。
3. 或参考 Apple 官方 AppEntity 在 Intent 间传递的完整样例，补齐缺的协议要求。

### 假设 B：items 有值，但 requestDisambiguation 循环的弹窗没渲染
若 items 非空却没弹窗，可能：
- `requestDisambiguation` 在**无 UI 上下文**时的行为（快捷指令自动化 vs 手动运行差异）。
  App Intent 在某些无前台场景下 requestXXX 可能直接 throw needsValueError 而非弹窗。
- 工作参数 `choice`/`amountInput`/`merchantInput` 声明为可选但被系统当作必填输入，
  运行前先弹窗要它们（而非在循环里按需弹）。**这点值得重点查** —— 可能需要给这些
  工作参数不同的声明方式（如不用 @Parameter，或标记为不在输入中请求）。
- `requestDisambiguation` 的 `IntentDialog` / 选项数组为空或异常。

**验证**：确认 items>0 后，在 `confirmOne` 的 `while` 首行和 `requestDisambiguation` 前后加日志，
看循环有没有进、requestDisambiguation 有没有被调、抛了什么错。

### 假设 C：工作参数污染了 Intent 的输入签名
`ConfirmExpenseIntent` 有 4 个 @Parameter：`items` + `choice`/`amountInput`/`merchantInput`。
后三个是「循环内承接每轮输入」的工作参数，**不应作为用户输入**。但 App Intents 可能把它们
都当成 Intent 的输入参数，导致运行前系统尝试逐个 resolve（先要 choice…），干扰主流程。
- **验证**：看运行时系统是不是在要 choice/金额/商户 这些，而不只是「条目」。
- **候选修法**：工作参数不该是 @Parameter。requestValue/requestDisambiguation 需要
  IntentParameter 投影（`$xxx`）才能调 —— 若不能用 @Parameter，需换实现方式（例如
  不复用同一 Intent 的参数，而是每类编辑用独立子 Intent，或用别的请求 API）。

---

## Mac 上的调试步骤（建议顺序）

1. 拉最新 `dev-zhanghaha`（commit 962627b 或更新），`cd OmnyApp && xcodegen generate`，
   Xcode 打开 `Omny.xcodeproj`，真机 Run。
2. 建快捷指令：`屏幕识别`（直接入库=关）→ `确认记账`，条目接屏幕识别输出。
   测试文本：「昨天午饭吃的牛肉面，花了220.25元」（可用「文本」动作喂给屏幕识别）。
3. 在 `ConfirmExpenseIntent.perform()` 首行加 `print("items=\(items.count)")`，
   在 `confirmOne` 循环首行、`requestDisambiguation` 前后加日志。用 Console.app 看设备日志
   （App Intent 进程的 print 在 Console 里，按进程名 Omny 过滤）。
4. 按假设 A→B→C 顺序看日志定位：items 到底几条？循环进没进？requestDisambiguation 抛错没？
5. 若确认是假设 A（AppEntity 传递问题），**最稳的修法大概率是把 Intent 输入参数从
   `[InboxItemEntity]` 换成 `[String]`（Payload JSON 数组）**，绕开 AppEntity resolve 机制。
   `InboxItemEntity.Payload` 已是 Codable，编解码现成。

## 备注
- 部署目标 iOS 18，但确认走的是 iOS 16 API，无版本门槛（不要升 SnippetIntent/iOS 26）。
- 本文在 `docs/` 已入库；设计稿 `confirm-intent-io.md` 与验证脚手架 `llm-parse-test/`
  在 Windows 协作者本地 `.design-preview/`（该目录 gitignore，未入库），需要可向其索取。
- Windows 侧编译不了 App 层，只能靠 CI（macOS job，dev-zhanghaha push 触发）+ 真机。
- OmnyCore 逻辑可在 WSL/Linux 跑（`.design-preview/llm-parse-test/` 是现成的验证脚手架）。
