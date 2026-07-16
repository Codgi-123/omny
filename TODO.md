# TODO

> 记录当前进行中的任务、待验证项与设计定论，动手前先看。已完成项归档到「已完成」，仅留必要索引。

## 进行中 / 待验证

### 重复待办 — 待真机验证（2026-07-16 已实现，设计定论见下方备忘）
- [ ] 真机过一遍：添加界面「重复」行与预设/自定义两层弹窗；勾选完成后快照进「已完成」、母条目滚到下一期；左滑「跳过」；通知按新截止重排；滴答待办不出现重复入口。

### 记账模块 — 待真机验证（主体已完成；issue #24 二次完善已落地，USB 装机逐轮实测过）
OmnyCore 全链路 + App 正式记账页均已实现并上线（实现现状见 `docs/expense-module-design.md`「八、实现现状」）。issue #24 参考稿完善（2026-07-16，见「已完成」）已在真机逐轮验收，**剩余验证项**：
- [ ] 配 LLM Key 后真实抽取 + 打标准确率；短信/截图多渠道去重效果；分析页环状图引线在分类多时是否拥挤。
- [ ] 待细化：需处理页 expense 低置信项文案；`needsReview` 阈值（当前 0.8）。

### 组件化分期路线（issue #10 问题2）
P0（查询谓词层/tab 重构/设置分层）与 P1（消纯复制）已完成，见「已完成」。剩余：
- [ ] P2：ItemListScreen 页面模板 + 删除统一进回收站（**需先定删除语义定论**——现状快递/收藏/待办走 `Trash.softDelete`，需处理页/记账详情等仍是 `context.delete` 硬删）。
- [ ] P3：Ingestor 收尾——llmEnrich 异步补全收拢、requestSync 防抖、saveOrLog 统一错误处理。

### 「确认记账」快捷指令弹窗 — 待 Mac 真机调试
- [ ] 真机上「确认记账」可编辑弹窗起不来（数据已传到、非记账能静默入库，但记账逐笔核对弹窗渲染失败，最终「没有记账」）。全上下文、根因假设与调试步骤见 `docs/confirm-expense-intent-handoff.md`。只有 Mac + 真机能调。

## 已搁置

### 公司电脑装机测试（优先级降低）
> 大概率已被 TestFlight 自动发布取代——公司手机直接装 TestFlight 就能用最新构建，不再依赖公司电脑侧载。仅当需要在公司改代码、即时真机调试时才值得做。

- [ ] （如仍需）在公司电脑跑命令行装机流程，验证能否绕过导致 ⌘R 失败的限制。背景：个人 MacBook 已确认根因是 `~/Desktop` 被 iCloud 同步接管写 `com.apple.FinderInfo` → codesign 报 detritus，解法是 `-derivedDataPath` 指到同步目录外（见 `CLAUDE.md`「已知陷阱」）。公司电脑待实测是否同因；若报 DDI/CoreDevice 进程错则可能真被 IT 限制，退回 `ideviceinstaller` 走 usbmux。

## 设计定论（备忘）

### 重复待办（2026-07-16 拍板并落地）
- 模型用「**单条滚动 + 完成快照**」（滴答“按到期日期重复”语义）：重复待办只有一条母条目，勾选完成时不置完成，而是落一条普通已完成待办作快照（进现有「已完成」区当历史），母条目 `todoDue` 滚到下一期。不做「模板生成 N 条实例」。
- 规则引擎在 `OmnyCore/TodoRepeatRule.swift`（配全量单测），编码串存 `InboxItem.todoRepeatRule`：`d:1` 每天 / `w:2:1,4` 每 2 周的周一和周四（1=周一…7=周日，周期锚定 due 所在周、周一起始）/ `m:1:1,15` 每月（**日多选**，与周对称；小月 clamp 到月末、不污染规则）/ `y:1:7-16` 每年 / `weekday` 工作日。月/年推算与周同构：**本周期内还有未过的选中日就先取本周期**，没有才跳 interval 周期。
- 交互定论：欠账补勾只滚到 now 之后第一期（不积压）；重复待办的「放弃」语义 = **跳过本次**（不设 abandoned、不落快照，直接滚动，按钮文案随之变「跳过」）；清除截止时间连带清空重复规则（规则挂在日期上）；时间/提醒/重复三者正交（时分随 due 保留，提醒按新截止重排）。
- 范围：**仅本地待办**（`source != .dida`），滴答重复走 RRULE 与全量拉取快照语义冲突，不接。UI 为 `DueDateSheet` 重复行 + `RepeatRuleSheet`（预设）/ `CustomRepeatSheet`（每 N 天/周/月/年 + 星期多选）两层。
- 已知留白：已完成区同名快照可能刷屏（v2 可折叠成「每天看书 ×7」）；「工作日」从自定义页确认会存成 `w:1:1,2,3,4,5`，回显落在「自定义」行（语义等价，未做归一）。

### 快捷指令
- App Intent 当「收纳箱」，快捷指令用内置动作抓上下文。
- 截图流程参考 Yore App：快捷指令内置 `截屏` 抓当前屏 → 喂 `RecognizeTodoIntent`（struct 名仍叫这个，实为通用识别四类），无需用户先手动截图。
- **快捷指令原子化**：解析与入库分离。「解析文本」「屏幕识别」加 `直接入库` 开关（默认开=直接入库；关=只解析输出 `[InboxItemEntity]` 给下游）；「确认记账」接收实体，记账逐笔弹可编辑列表核对、非记账静默入库。确认弹窗刻意**不用 SnippetIntent**（iOS 26），改用 iOS 16+ 的 `requestDisambiguation` 参数请求循环（部署目标 iOS 18 要兼容）。跨 Intent 传值靠单个 `@Property` 存 Payload JSON（AppEntity 裸字段会丢）。

### 记账模块（2026-07-11 拍板，详见 `docs/expense-module-design.md`）
定位「捕获层 + 轻账本」，`expense` 作第 6 类 kind 复用现有管线，不做账户体系/预算/报表。要点：入口复用现有「解析文本」快捷指令（`.expense` 进白名单）+ 识屏 ScreenParser；方向本期只支出/收入，其余走 `needsReview`；金额用 `Decimal`（禁 Double）；消费分类两级（大类+细分），扁平化 enum-schema 打标；去重用 txnID 精确 / 金额+时间窗+尾号或商户 模糊；微信/支付宝 CSV 导入本期不做（`txnID` 已预留）。

### tab 扩容三级路径（2026-07-15 拍板，issue #10 问题1 后续，HIG 评审结论）
5 tab 已满（今天 / 包裹·行程 / 记账 / 待办 / 收藏），后续新增功能模块**不再动导航架构**，按下列顺序升级承载，先问「它像谁」：
1. **语义归并进现有 tab（首选）**：新模块与现有某类语义相近时，做成该 tab 顶部分段控件的一个分段（「包裹·行程」已示范；先例：系统电话 App「未接/全部」）。HIG 下单 tab 分段 2~3 段内为宜，超出即升级下一级。
2. **最低频 tab 换「我的」聚合页**：出现语义独立、不够高频的模块时，把使用频率最低的 tab（大概率收藏）降级进「我的」列表页，收纳收藏 + 新模块 + 需处理 + 回收站 + 设置（先例：微信「我」/支付宝「我的」；评审确认与合并方案不互斥，可直接叠加）。
3. **tab 自定义配置（除非模块多到频率因人因时而异，否则不做）**：支付宝金刚区式「编辑我的 tab」。评审明确排最后：iPhone 无原生支撑、单用户 App 建通用配置系统属过度设计。
已备好的地基：`RootTab` enum（增删换 tab = 一个 case + 一个根视图，持久值自动回落）；P2 `ItemListScreen` 模板落地后新 kind 页面近乎声明式；新模块配置项落设置页「常用」区，功能主入口**不得**再挂设置页（记账迁 tab 前的错位不重演）。

### 设置页分层（2026-07-14 拍板，issue #10 问题3，HIG 评审 8.5 分方案）
- 一级页按使用频率分层：**服务（状态行）→ 常用 → 数据 → 高级设置 → 帮助 → 关于**；二级页拆在 `Views/Settings/`（LLM / 滴答 / 高级 / 快捷指令教程 / 开发者工具）。
- 服务行副标题只显示「模型名 · 已配置 / 未配置」「已绑定 · 上次同步 x 前 / 未绑定」——连通性测试结果是临时态，**不持久化、不冒充「已连通」**。
- 低频参数全部可配置化但**默认值 = 原硬编码值**（阈值 0.8 / 截图待办直接入库关 / 去重窗 ±10min / 滴答防抖 30s / 航班缓存 10min / 回收站 7 天 / maxTokens 2048 / 超时 60s），键留 UserDefaults.standard，`resetToDefaults()` 同步重置。
- LLM maxTokens/超时经 `LLMConfig`（新增字段，默认参数向后兼容）由 App 层注入 OmnyCore，**OmnyCore 不读 UserDefaults**；打标 256 / 分类 128 的小预算不受 maxTokens 设置影响。`InboxItem.trashRetentionDays` 因模型层非 MainActor 直接读同名 UserDefaults 键（"data.trashRetentionDays"），改键名要与 AppSettings 两处同步。
- 开发者工具（解析测试）是**可见的** NavigationLink（关于 Section 内），HIG 评审否决连点解锁；版本号改读 Bundle。危险操作（清空条目/恢复出厂）收进高级设置页底部红色组。

## 已完成

- [x] 记账功能二次完善（2026-07-16，issue #24，参考钱迹风格四图 + HIG 评审）：① **45 个自绘 SVG 分类图标**（`Assets.xcassets/ExpIcon*`，24×24 线稿 1.8pt 圆头描边，与收藏页 BookmarkLink 同风格，template 渲染）全面替换记账 SF Symbol；`ExpenseCategoryAppearance` 改 `CategoryIcon.asset/.symbol` 双态（旧用户覆盖 SF 名向后兼容，新覆盖存 `svg:资产名|colorKey`），预置表额外收录旅行/宠物/教育等常见自定义分类名；渲染组件 `ExpenseCategoryChip`（**中性灰底+灰线稿**，对齐收藏页 BookmarkKindIcon 的安静风格；彩色底方案被用户否掉——"太丑"，分类色只留给分析页图表）/`CategoryIconGlyph`（裸线稿）收进 `Views/Components/ExpenseCategoryIcon.swift`；记账页残余图形性 SF Symbol 一并换自绘 SVG（备注笔 ExpIconNote、键盘退格 ExpIconBackspace、空态钱袋），方向性 chevron 与系统操作词汇（trash/plus/FAB）按 HIG 保留系统符号。② **明细页**：汇总卡改「本月支出」主角（收入/结余降次级），记账行升级两栏（大类·细分 + 时刻·备注 / 金额 + 渠道尾号），金额语义色支出红/收入绿全链路统一（行/详情/汇总）；新增 `ExpenseFormat.balance`（负结余 "-¥77.00"，修掉原 "¥-77.00"）。③ **记一笔**：分类选中态从蓝描边圈改「点亮」——未选中裸线稿（无底），选中系统蓝底+白线稿（snappy 过渡）；金额与完成键随方向红/绿（`directionTint`）；金额数字 `contentTransition(.numericText())`；时间卡新增常驻备注行（`InboxItem.expenseNote` 可选字段轻量迁移，`addManualExpense` 加 `note:` 参数，详情页显示、行内 caption 备注优先于商户）。④ **分析页**：顶部新增收支统计宫格（支出/收入/结余/日均支出，日均按本月已过天数或历史月整月摊）；环状图/排行改用分类签名色（撞色顺延取未用色，行图标↔扇区一色）；大类排行行升级图标 chip + 占比进度条 + 一位小数占比。⑤ 分类管理页图标选择器换自绘 SVG 库网格。后续同日按真机反馈迭代：图标统一圆形灰底；细分面板改在父类所在行下方就地展开（灰底分区 + 「…」角标）；记一笔改三段式（宫格→单张信息卡→灰底白键键盘，仅完成键带色）；键盘四等宽列、+×/−÷ 单键循环、完成键固定文案且未算完直接按全式结果入库、全键触感、长按退格清空；宫格「设置」直达分类管理。剩余验证项见「进行中」。
- [x] 收藏页优化（2026-07-15，issue #18）：① 红粉色 IconChip 换自绘 SVG 线稿图标（BookmarkLink 锁链 / BookmarkNote 图文页，`BookmarkKindIcon` 中性灰底，今天页同步）；② 绿字标签换 `TagPill` 药丸（TagPicker.swift，只读 Capsule）；③ 链接型 tap 直接 openURL（失败兜底进详情，详情入口移长按菜单），图文型进全屏 `BookmarkDetailView`；④ iOS 18 `navigationTransition(.zoom)` + `matchedTransitionSource(id: item.id)` 拿到非线性放大进入、左缘滑动返回、缩回源行——宿主用 `fullScreenCover` 而非 push（push+zoom 在 List 交互滑返有框架级残影 bug 且 tab 栏不回弹，Apple 论坛 thread 810944）；⑤ 详情页通栏无框排版（原 `BookmarkDetailSheet` Form 分框已删），配图 tap 经独立 photoNS zoom 进全屏 `ZoomableImageView`（捏合 1–4x 橡皮筋、双击 2.5x、放大后拖拽、未放大单击关闭/下拉缩回）；编辑改同页 toolbar 切换（全屏 TextEditor），保存语义与原 Sheet 一致。跟进（同日）：首页整页 ScrollView→List（swipeActions 是 List 行专属；SDK 26.5 无 iOS 27 的 swipeActionsContainer），今日收藏行原生左滑 加代办(绿)/标签(蓝)/删除(红)，收藏页左滑同款并补加代办；「加代办」预填 TodoQuickAdd（标题「查看收藏：{缩写}」，描述=完整标题+链接；TodoQuickAdd 支持预填参数，逻辑收敛 `InboxItem.bookmarkTodoPrefill`）；TodoRow 加 `showsSwipeActions` 开关（首页多条合一个 List 行，否则左滑整卡一起滑）；两个坑（模拟器 cliclick 实测定位）：iOS 26 下 List 行距设 0 会让滑动按钮退化成旧式方块（勿设 `listRowSpacing(0)`）；destructive 原生红会被同组邻位按钮 tint 串染，需显式 `.tint(.red)`。
- [x] 高铁/酒店卡片重设计 + 三种行程卡同高（2026-07-15）：`TripCard` 改三段定高骨架（头部 44 / 路线 60 / 地面信息 48，发丝线一律 overlay 不占高度）⇒ 机票·火车·酒店卡总高严格一致。火车卡对齐票面参考稿：车次+日期头部、大字时刻+轨道线（正中高铁图标）、灰底四格「检票口/车厢/座位/席别」（车厢座位从 seat 正则拆分）；酒店卡：房型副标题（可含早餐说明）、入住/退房大字日期+「N晚」胶囊+时刻提示（14:00后可入住式）、底部地址行+导航（拉起系统地图）。解析链路同步补字段：`TripInfo` 新增 `ticketGate`/`seatClass`/`address`，短信与识屏两个 trip prompt+schema、RuleParser 火车正则（检票口/席别）、InboxItem、Ingestor、InboxItemEntity.Payload 全链路透传。
- [x] 组件化 P1「消纯复制」（2026-07-15，issue #10 问题2）：纯复制 UI 收敛到 `Views/Components/` 5 个新文件——CollapsibleSectionHeader（待办页 3 处折叠组头收编，chevron 按 HIG 收起指右/展开指下）；SelectableChip + TagPicker（收藏添加/详情两处多选 chip 与筛选栏单选 chip 收编，`filterStyle` 参数保留筛选栏刻意差异；FlowLayout 随迁；「配置池+已用值」合并收敛为 `AppSettings.mergedTagCandidates`）；CheckToggleButton（取件圈×2 + 待办勾选收编，命中区保底 44pt 自动外扩，取件双向推进业务包装成 Cards.swift 的 PickupCheckButton）；FloatingAddButton 参数化（记账页内联 FAB 收编，`size: 56` 保留原尺寸差异）；OmnyDateFormat（6 处「每次调用 new DateFormatter」收敛为静态实例复用，日历裸紧凑金额并入 `ExpenseFormat.compactBare`）。
- [x] 设置页按使用频率分层重构（2026-07-14，issue #10 问题3）：定论见上方「设计定论 → 设置页分层」。
- [x] 正式 5 tab 结构落地（2026-07-14，issue #10 问题1）：**今天 / 包裹·行程 / 记账 / 待办 / 收藏**。快递+行程合并进「包裹·行程」tab（`PackageTripView` 薄容器，顶部纯文字分段控件切换，分段选择持久化 `omnyPackageTripSegment`，同键兼作首页「查看详情」的跨页传参通道）；腾出的 tab 给记账，`ExpenseHomeView` 升 tab 根视图并挂 NavActions，设置页仅保留「消费分类 / 解析测试」入口（设置页重构时再安置）。tab 标识改 `RootTab` enum：`omnySelectedTab` 旧整数越界自动回落「今天」，旧 2(行程) 首启落到记账一次可接受；`-omnyTab N` 按新序。遗留：TabPackageTrip / TabExpense 图标为对齐既有线稿风格的自绘 SVG，真机看效果后可再打磨。
- [x] 文档梳理与整合（2026-07-13）：按最新代码更新 README/CLAUDE/docs，记账模块与识屏入口补全；CI 规则以 CLAUDE.md 为权威源、他处引用；新增 `docs/README.md` 文档索引防熵增。
- [x] TestFlight 自动发布上线（2026-07-12，PR #5 合入 main）：打 `tf-*` tag 或手动触发即云端归档上传，约 4 分钟；构建号 CI 自动生成（run_number+偏移），多人发布不撞号、不改 project.yml；ASC API Key 云签名，协作者无需 Apple 凭据。用法见 `docs/testflight-release.md`。同批 `ci.yml` 未签名 ipa job 改为仅手动触发，push 不再自动出包。
- [x] 记账模块 v1（2026-07-11 → 07-12，build 13–19）：OmnyCore 数据契约 + 解析（含识屏第四类、口语措辞）+ 两级 enum-schema 打标 + 去重入库 + 手动记账；App 正式记账页（明细/日历/分析 DonutChart/详情/编辑 + 自制计算器键盘）+ 分类图标映射器。实现现状与待验证见 `docs/expense-module-design.md`。
- [x] 快递卡取件交互按 HIG 重做（2026-07-11，dev-kiwi build 7）：取件码/单号 SF Rounded 圆润数字随 Dynamic Type 缩放；点取件码即复制；「确认取件」改提醒事项式勾选圈（symbol 替换动画 + 成功触感）；列表整条右滑完成/撤销；首页卡片取消长按菜单；全局日期锁 zh_CN。同批把 dev-zhanghaha 的屏幕识别（ScreenParser）、需处理「重新识别」合并进 dev-kiwi。
- [x] 快捷指令导入接线（2026-07-10）：「解析文本」与「截图识别待办」两条 iCloud 链接接入 SettingsView，各有导入按钮 + 图文引导；后者手动触发（背面轻点 / 控制中心，iOS 无"截屏就运行"触发器）。
- [x] SettingsView 加「快捷指令」Section：「解析文本」导入按钮 + 两步图文引导。
- [x] LLM 调用收敛到 `LLMClient` 公共底座（2026-07-09）：结构化输出 400 降级重试、围栏剥离、maxTokens 统一进底座，删 `LLMResponseParsing.swift`。
- [x] 修复 CI Linux 编译失败（2026-07-09）：`DidaSyncTests` 补 `FoundationNetworking` 条件导入。
