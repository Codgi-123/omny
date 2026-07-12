# TODO

## 2026-07-10 — 公司电脑装机测试

> **2026-07-12 更新：此条大概率已被 TestFlight 自动发布取代**——公司手机直接装 TestFlight 就能用上最新构建，不再依赖公司电脑侧载。仅当需要在公司改代码、即时真机调试时才值得做，优先级降低。

### 我（用户）要做
- [ ] 在公司电脑上跑命令行装机流程，验证能否绕过导致 command+R 失败的限制

背景：个人 MacBook 上已确认根因是 `~/Desktop` 被 iCloud/云同步接管，同步服务给文件写 `com.apple.FinderInfo` 扩展属性 → codesign 报 `resource fork, Finder information, or similar detritus not allowed`。解法是把编译产物 `-derivedDataPath` 指到同步目录外。公司电脑待实测是否同因。

测试步骤：
```bash
# 1. 编译（产物放同步目录外）
xcodebuild -project OmnyApp/Omny.xcodeproj -scheme Omny -configuration Debug \
  -sdk iphoneos -derivedDataPath ~/OmnyBuild build
# 2. 查设备 ID（公司电脑上可能不同）
xcrun devicectl list devices
# 3. 装到手机
xcrun devicectl device install app --device <设备ID> \
  ~/OmnyBuild/Build/Products/Debug-iphoneos/Omny.app
```
- [ ] 若仍报 detritus → 同步目录问题，把项目整体移出 `~/Desktop`/`~/Documents`
- [ ] 若报 DDI/CoreDevice 进程相关错 → 真被 IT 限制，退回 `brew install ideviceinstaller` 走 usbmux 通道

---

### 进行中
- **记账模块 v1 首版**（2026-07-11，dev-zhanghaha）：OmnyCore 全链路已实现并测过（114 测试全绿）。
  - 已完成：`ItemType.expense` / `ExpenseDirection` / `ExpenseInfo` / `ParsedPayload.expense`；`RuleParser.classify` 记账双命中判定 + `extractExpense` 正则降级；`LLMStructuredParser.parseExpense`（prompt+schema）；`LLMExpenseCategorizer` 两级 enum-schema 打标；`ExpenseParserTests` + `RealSMSTests` 补脱敏银行短信基线。App 侧：`InboxItem` 记账字段 + `expenseDirection`；`Ingestor.ingestExpense`（txnID 精确 / 金额+时间窗±10min+尾号/商户 模糊去重）+ 异步补分类；`.expense` 进「解析文本」白名单 + `intentSummary`；`AppSettings` 两级分类池（JSON 存 UserDefaults）+ `expenseCategorizer`；设置页临时调试入口 `ExpenseDebugView`（粘贴短信解析入库 + expense 列表）。
  - **手动记账**（2026-07-11 追加）：新增 `Ingestor.addManualExpense`（用户填的字段直接入库，**不走解析、不模糊去重、不异步 LLM 补分类**——尊重用户明确输入；支持 `editing:` 回写已有条目）。
  - **识屏记账 + 口语解析**（2026-07-12）：`ScreenParser` 补第四类 expenses（此前识屏不认记账，支付截图落未分类）；`RuleParser` expenseVerbs/incomeKeywords 增口语措辞（买/花/充值/收到/卖…）让手输/语音文本能记账。
  - **分类图标方案**（2026-07-12）：图标/颜色与分类池解耦（LLM 只用名字打标，不需外观）。`Theme.ExpenseColor` 签名色板；`ExpenseCategoryAppearance` 映射器（用户覆盖→预置库→tag.fill+按名 hash 兜底），复用 IconChip 渲染。
  - **正式记账页**（2026-07-12）：`Views/Expense/` 下全套 SwiftUI，风格沿用现有体系（ScreenHeader/cardCell/IconChip/Theme）：
    - `ExpenseHomeView` 容器（明细/日历/分析 分段内联标题行 + 月份切换 + FAB，三视图共享月份）
    - 明细（结余/支出/收入大卡 + 天分组 ExpenseRow）；日历（月历网格每天收支 + 选中展开）；分析（DonutChart 原生环状图 + 引线图例 + 大类→细分→单据下钻）
    - `ExpenseDetailView` 详情（大图标+字段，空字段隐藏，编辑/删除）
    - `ExpenseEditView` 添加/编辑（方向切换内联导航行 + 分类宫格 + 细分展开 + 时间常驻 + 更多信息折叠 + **自制计算器键盘**）；取代旧 `ManualExpenseView`（已删）
    - `ExpenseCalculator`（OmnyCore，+−×÷/乘除优先级/Decimal 精度，19 单测全绿）；`ExpenseSupport`（金额格式化 + 月/天/分类聚合 + ExpenseRow）
    - 设置页入口：「记账」→ ExpenseHomeView（正式）；「解析测试（调试）」→ ExpenseDebugView（保留）
  - 待验证：~~① XcodeGen 收录 Views/Expense/ 新文件；② macOS 编译（含 DonutChart/日历网格/计算器 UI、SF Symbol 名）~~——已验证（2026-07-12 TestFlight CI 的 xcodegen generate + Release 归档全绿，build 18/19 已上传）；剩余需真机实测（装 TestFlight build 19）：③ 环状图引线在分类多时是否拥挤；④ 配 LLM Key 后真实抽取+打标；⑤ 去重多渠道效果。
  - 待细化：需处理页 expense 低置信项文案；needsReview 阈值（0.8）；设置页「记账分类自定义」UI（图标/颜色选择器，映射器接口已预留）。
  - 设计文档：`docs/expense-module-design.md`。

### 已完成
- [x] TestFlight 自动发布上线（2026-07-12，PR #5 已合入 main）：打 `tf-*` tag 或 Actions 页面手动触发即云端归档上传，约 4 分钟；构建号 CI 自动生成（run_number + 偏移），多人发布不撞号、不用改 project.yml；签名走 ASC API Key 云签名，协作者无需任何 Apple 凭据。用法见 `docs/testflight-release.md`。**@zhanghaha：在 dev-zhanghaha 上 merge 一次 main 即可使用**（顺带会拿到 ci.yml 更新——未签名 ipa job 已改为仅手动触发，push 不再自动出包）。
- [x] 快递卡取件交互按 HIG 重做（2026-07-11，dev-kiwi 发布 build 7）：取件码/单号改 SF Rounded 圆润数字并随 Dynamic Type 缩放；点取件码即复制；「确认取件」改为提醒事项式勾选圈（空心圈→绿色对勾，symbol 替换动画 + 成功触感，与数字中心对齐）；快递列表页整条右滑完成/撤销；首页卡片取消长按菜单；全局日期锁 zh_CN。同批把 dev-zhanghaha 的屏幕识别（ScreenParser）、需处理「重新识别」等功能合并进 dev-kiwi
- [x] 快捷指令导入接线（2026-07-10）：「解析文本」（`78b9cbce…`）与「截图识别待办」（`f37dc8b6…`）两条 iCloud 链接接入 SettingsView，各有导入按钮 + 图文引导；后者手动触发（背面轻点 / 控制中心，iOS 无"截屏就运行"触发器）
- [x] SettingsView 加「快捷指令」Section：「解析文本」导入按钮（占位链接）+ 两步图文引导
- [x] LLM 调用收敛到 `LLMClient` 公共底座（2026-07-09）：结构化输出 400 降级重试、围栏剥离、maxTokens 统一进底座，删 `LLMResponseParsing.swift`
- [x] 修复 CI Linux 编译失败（2026-07-09）：`DidaSyncTests` 补 `FoundationNetworking` 条件导入；此前 main/dev-kiwi 线的 core-linux 一直是红的

### 设计定论（备忘）
- App Intent 当「收纳箱」，快捷指令用内置动作抓上下文。
- 截图流程参考 Yore App（`c.team.Yore.SaveYore`）：快捷指令内置 `截屏` 抓当前屏 → 喂 `RecognizeTodoIntent`，无需用户先手动截图。
- `RecognizeTodoIntent` 保留 `image` 参数即可；`note` 参数已决定不加。

### 记账模块（2026-07-11 设计拍板，详见 `docs/expense-module-design.md`）
定位「捕获层 + 轻账本」，新增 `expense` kind 复用现有管线，不做账户体系/预算/报表。已拍板决策：
- **入口 1+2 复用现有通道、零新增入口代码**：① 银行短信走现有「解析文本」快捷指令（只需把 `.expense` 加进白名单）；② 支付页截图走现有识屏 ScreenParser（全放行，不用动）。③ 微信/支付宝 CSV 导入本期不做，作为后续增量（字段 `txnID` 已预留）。
- **方向**：本期只支持支出/收入两类（`ExpenseDirection`）；转账/退款等走 `needsReview`，后续扩枚举。
- **金额用 `Decimal`**（禁 Double），LLM 输出字符串再本地转。
- **消费分类做两级**（大类 + 细分，两个字段），打标用扁平化 enum-schema（`"餐饮/午餐"` 拍平进 enum），复刻 `LLMTagClassifier` 的「只能从池里挑」机制，新增 `LLMExpenseCategorizer`。
- **去重**：CSV 用官方 `txnID` 精确去重；短信/截图用「金额 + 时间窗 + 尾号/商户」模糊去重。
- **临时入口**：先在设置页放调试用的手动输入 + expense 列表，跑通端到端；正式 tab 结构（倾向快递+行程合并腾位）待验证后再调整。
- 实施分期与验证边界见设计文档「八、实施分期」。
