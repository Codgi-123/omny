# TODO

## 2026-07-10 — 公司电脑装机测试

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
  - **手动记账**（2026-07-11 追加）：新增 `Ingestor.addManualExpense`（用户填的字段直接入库，**不走解析、不模糊去重、不异步 LLM 补分类**——尊重用户明确输入；支持 `editing:` 回写已有条目）；新建 `ManualExpenseView` 表单页（方向切换 / 金额 Decimal 校验 / 两级分类选择器从池里选 / 商户·渠道·卡尾号·时间）；`ExpenseDebugView` 加「手动记账」入口按钮 + 列表行点击进表单编辑（sheet 弹出）。
  - 待验证（需 macOS/真机，本机无法测）：① CI macOS job 编 App 是否过；② 配 LLM Key 后真实银行短信抽取 + 两级打标准确率；③ 去重在多渠道重复时的实际效果。
  - 待细化：需处理页 expense 低置信项目前显示为「未分类」Badge，正式化时区分文案；expense 低置信标 needsReview 的阈值（当前沿用 0.8）。
  - 设计文档：`docs/expense-module-design.md`。

### 已完成
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
