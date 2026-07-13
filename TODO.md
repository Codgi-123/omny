# TODO

> 记录当前进行中的任务、待验证项与设计定论，动手前先看。已完成项归档到「已完成」，仅留必要索引。

## 进行中 / 待验证

### 记账模块 — 待真机验证（主体已完成，build 19）
OmnyCore 全链路 + App 正式记账页均已实现并上线（实现现状见 `docs/expense-module-design.md`「八、实现现状」）。**剩余只差真机实测**（本机无 Key/无法编译 App，覆盖不到）：
- [ ] 装 TestFlight build 19，验证：① 分析页环状图引线在分类多时是否拥挤；② 配 LLM Key 后真实抽取 + 打标准确率；③ 短信/截图多渠道去重效果。
- [ ] 待细化：需处理页 expense 低置信项文案；`needsReview` 阈值（当前 0.8）；设置页「记账分类自定义」的图标/颜色选择器 UI（映射器接口已预留）。

### 「确认记账」快捷指令弹窗 — 待 Mac 真机调试
- [ ] 真机上「确认记账」可编辑弹窗起不来（数据已传到、非记账能静默入库，但记账逐笔核对弹窗渲染失败，最终「没有记账」）。全上下文、根因假设与调试步骤见 `docs/confirm-expense-intent-handoff.md`。只有 Mac + 真机能调。

### 正式 tab 结构（需求稳定后再做）
- [ ] 记账目前经设置页入口（`ExpenseHomeView`），未占正式 tab。倾向「快递 + 行程合并腾位」给记账，等记账需求稳定后再调整 5 tab 结构。

## 已搁置

### 公司电脑装机测试（优先级降低）
> 大概率已被 TestFlight 自动发布取代——公司手机直接装 TestFlight 就能用最新构建，不再依赖公司电脑侧载。仅当需要在公司改代码、即时真机调试时才值得做。

- [ ] （如仍需）在公司电脑跑命令行装机流程，验证能否绕过导致 ⌘R 失败的限制。背景：个人 MacBook 已确认根因是 `~/Desktop` 被 iCloud 同步接管写 `com.apple.FinderInfo` → codesign 报 detritus，解法是 `-derivedDataPath` 指到同步目录外（见 `CLAUDE.md`「已知陷阱」）。公司电脑待实测是否同因；若报 DDI/CoreDevice 进程错则可能真被 IT 限制，退回 `ideviceinstaller` 走 usbmux。

## 设计定论（备忘）

### 快捷指令
- App Intent 当「收纳箱」，快捷指令用内置动作抓上下文。
- 截图流程参考 Yore App：快捷指令内置 `截屏` 抓当前屏 → 喂 `RecognizeTodoIntent`（struct 名仍叫这个，实为通用识别四类），无需用户先手动截图。
- **快捷指令原子化**：解析与入库分离。「解析文本」「屏幕识别」加 `直接入库` 开关（默认开=直接入库；关=只解析输出 `[InboxItemEntity]` 给下游）；「确认记账」接收实体，记账逐笔弹可编辑列表核对、非记账静默入库。确认弹窗刻意**不用 SnippetIntent**（iOS 26），改用 iOS 16+ 的 `requestDisambiguation` 参数请求循环（部署目标 iOS 18 要兼容）。跨 Intent 传值靠单个 `@Property` 存 Payload JSON（AppEntity 裸字段会丢）。

### 记账模块（2026-07-11 拍板，详见 `docs/expense-module-design.md`）
定位「捕获层 + 轻账本」，`expense` 作第 6 类 kind 复用现有管线，不做账户体系/预算/报表。要点：入口复用现有「解析文本」快捷指令（`.expense` 进白名单）+ 识屏 ScreenParser；方向本期只支出/收入，其余走 `needsReview`；金额用 `Decimal`（禁 Double）；消费分类两级（大类+细分），扁平化 enum-schema 打标；去重用 txnID 精确 / 金额+时间窗+尾号或商户 模糊；微信/支付宝 CSV 导入本期不做（`txnID` 已预留）。

## 已完成

- [x] 文档梳理与整合（2026-07-13）：按最新代码更新 README/CLAUDE/docs，记账模块与识屏入口补全；CI 规则以 CLAUDE.md 为权威源、他处引用；新增 `docs/README.md` 文档索引防熵增。
- [x] TestFlight 自动发布上线（2026-07-12，PR #5 合入 main）：打 `tf-*` tag 或手动触发即云端归档上传，约 4 分钟；构建号 CI 自动生成（run_number+偏移），多人发布不撞号、不改 project.yml；ASC API Key 云签名，协作者无需 Apple 凭据。用法见 `docs/testflight-release.md`。同批 `ci.yml` 未签名 ipa job 改为仅手动触发，push 不再自动出包。
- [x] 记账模块 v1（2026-07-11 → 07-12，build 13–19）：OmnyCore 数据契约 + 解析（含识屏第四类、口语措辞）+ 两级 enum-schema 打标 + 去重入库 + 手动记账；App 正式记账页（明细/日历/分析 DonutChart/详情/编辑 + 自制计算器键盘）+ 分类图标映射器。实现现状与待验证见 `docs/expense-module-design.md`。
- [x] 快递卡取件交互按 HIG 重做（2026-07-11，dev-kiwi build 7）：取件码/单号 SF Rounded 圆润数字随 Dynamic Type 缩放；点取件码即复制；「确认取件」改提醒事项式勾选圈（symbol 替换动画 + 成功触感）；列表整条右滑完成/撤销；首页卡片取消长按菜单；全局日期锁 zh_CN。同批把 dev-zhanghaha 的屏幕识别（ScreenParser）、需处理「重新识别」合并进 dev-kiwi。
- [x] 快捷指令导入接线（2026-07-10）：「解析文本」与「截图识别待办」两条 iCloud 链接接入 SettingsView，各有导入按钮 + 图文引导；后者手动触发（背面轻点 / 控制中心，iOS 无"截屏就运行"触发器）。
- [x] SettingsView 加「快捷指令」Section：「解析文本」导入按钮 + 两步图文引导。
- [x] LLM 调用收敛到 `LLMClient` 公共底座（2026-07-09）：结构化输出 400 降级重试、围栏剥离、maxTokens 统一进底座，删 `LLMResponseParsing.swift`。
- [x] 修复 CI Linux 编译失败（2026-07-09）：`DidaSyncTests` 补 `FoundationNetworking` 条件导入。
