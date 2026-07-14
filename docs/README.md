# docs/ 文档索引

后续 agent / 协作者的导航页：先看这里定位「改某个主题该读/改哪份文档」，避免逐个打开翻找。

## 全局入口（在仓库根目录，不在本目录）

| 文件 | 讲什么 | 何时读 |
|---|---|---|
| `../CLAUDE.md` | Agent 操作总纲：架构主线、数据流、已知陷阱、**分支与 CI（权威源）**、设计原则、常用命令 | 动手改任何代码前，第一份 |
| `../README.md` | 人类协作者上手：功能概览、架构树、macOS/Windows 开发环境、装机方式、CI 速查 | 新人入门、搭环境 |
| `../TODO.md` | 进行中任务、待验证项、设计定论、已完成归档 | 动手前看有没有相关在途工作或已拍板结论 |

## 本目录（docs/）

| 文件 | 讲什么 | 何时读 |
|---|---|---|
| `parsing-architecture.md` | **解析架构权威源**：为什么「分类靠正则、结构化靠 LLM」；两个 LLM 入口（短信整段归一类 vs 截图一屏多类）；数据流图；关键类型职责；踩过的坑（宽容日期解析） | 改解析管线、加新短信/截图类型、动 LLM parser 前 |
| `expense-module-design.md` | **记账模块架构文档**：数据契约（`ExpenseInfo`/`Decimal`）、两级 enum-schema 打标、模糊去重策略、入口现状、实现现状与待验证 | 改记账相关代码前 |
| `confirm-expense-intent-handoff.md` | 交接：「确认记账」快捷指令可编辑弹窗真机起不来（**bug 未解决**），含根因假设与 Mac 调试步骤 | 接手调这个弹窗 bug 时（需 Mac + 真机） |
| `testflight-release.md` | 发布到 TestFlight：CI 自动发布（首选）+ 本地命令行全流程（备用）、ASC API Key 配置、踩坑 | 要发版、配发布密钥时 |
| `dev-notes-windows.md` | Windows/WSL2 开发 OmnyCore 的踩坑与结论（`FoundationNetworking` 导入、切版本清 `.build`、WSL 装非 C 盘） | 在 Windows 上搭核心层开发环境、遇跨平台编译错时 |
| `ExportOptions.plist` | TestFlight 导出配置（被 `testflight-release.md` 引用） | 不单独看，配合发布流程 |

## 约定：主题的「权威源」

同一主题若在多处出现，改动只需改权威源，其他处引用（此表就是为防「改一处漏三处」的熵增）：

| 主题 | 权威源 | 其他处 |
|---|---|---|
| 分支与 CI 规则 | `../CLAUDE.md`「分支与 CI」 | README、testflight-release、confirm-handoff 均引用 |
| 解析架构与设计原则 | `parsing-architecture.md` | CLAUDE.md / README 存精简版 + 链接 |
| 记账模块设计 | `expense-module-design.md` | CLAUDE.md 数据流、README 取舍节存要点 + 链接 |
| 已知陷阱（detritus / 7 天签名） | `../CLAUDE.md`「已知陷阱」 | README、testflight 引用 |
