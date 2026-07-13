# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概况

Omny：个人信息收件箱 iOS App（自用，不上架）。把短信、截图、系统分享里的信息解析成结构化条目（快递/行程/待办/收藏/记账）统一管理。代码注释与 UI 均为中文。

## 常用命令

```sh
# 核心层测试（唯一的测试套件，跨平台可跑）
cd OmnyCore && swift test

# 跑单个测试类 / 单个测试方法
swift test --filter RuleParserTests
swift test --filter RuleParserTests/testSomething

# 生成 Xcode 工程（project.pbxproj 是 XcodeGen 生成物；改 target 配置要改 project.yml 后重新生成）
cd OmnyApp && xcodegen generate

# 命令行编译 + 真机安装（注意 -derivedDataPath 必须指到 iCloud 同步目录之外，见下文陷阱）
xcodebuild -project OmnyApp/Omny.xcodeproj -scheme Omny -configuration Debug \
  -sdk iphoneos -derivedDataPath ~/OmnyBuild build
xcrun devicectl list devices
xcrun devicectl device install app --device <设备ID> \
  ~/OmnyBuild/Build/Products/Debug-iphoneos/Omny.app

# 打包上传 TestFlight（命令行全流程，含 ASC API Key 配置与踩坑）见 docs/testflight-release.md
```

首次搭建需要密钥：`cp OmnyApp/Secrets.swift.example OmnyApp/Omny/Services/Secrets.swift`（滴答清单 client_id/secret，向维护者索要）。`Secrets.swift` 和根目录 `Secrets.local.json` 已被 .gitignore 排除，禁止提交。LLM API Key 不进代码，运行时在 App 设置页填。

## 已知陷阱

- **codesign 报 `resource fork, Finder information, or similar detritus not allowed`**：根因是项目位于 `~/Desktop`（被 iCloud 同步接管，同步服务写 `com.apple.FinderInfo` 扩展属性）。解法：编译产物用 `-derivedDataPath` 指到同步目录外（如 `~/OmnyBuild`）。
- 免费 Apple ID 签名 7 天过期，重新 ⌘R / 重装即可。
- `OmnyApp/` 只能在 macOS 编译（Apple 限制）；`OmnyCore/` 在 macOS / Linux / WSL 均可开发测试（WSL 环境踩坑见 `docs/dev-notes-windows.md`）。
- Linux 上 `URLRequest`/`URLSession`/`HTTPURLResponse` 在 `FoundationNetworking` 模块：用到网络类型的文件（含测试）都要加 `#if canImport(FoundationNetworking) import FoundationNetworking #endif`，否则 macOS 编译过、CI 的 Linux job 挂。

## 架构

两层分离是本项目的核心结构：

- **`OmnyCore/`** — 纯 Swift 逻辑包（SwiftPM，无 UI 依赖，跨平台）。所有解析、LLM 调用、滴答同步逻辑都在这里，配套全量单测。
- **`OmnyApp/`** — SwiftUI 壳（XcodeGen 管理），含主 App target `Omny` 和分享扩展 target `OmnyShare`，通过 App Group `group.xin.codgi.omny` 共享数据。

### 数据流（读多个文件才能看清的主线）

1. **统一模型**：所有入口的信息都落成同一个 SwiftData 实体 `InboxItem`（`OmnyApp/Omny/Models/InboxItem.swift`，扁平结构、各类型字段可空共存）。六类 `kind`（快递/行程/待办/收藏/记账）都是按 `kind` 过滤的视图；页面结构仍是 5 tab（今天/快递/行程/待办/收藏），**记账（`expense`）暂走设置页「记账」入口 `ExpenseHomeView`**（明细/日历/分析三视图），未占正式 tab。
2. **解析管线**：「分类靠正则、结构化靠 LLM」（详见 `docs/parsing-architecture.md`）。组装点在 `AppSettings.parserPipeline`：配了 LLM 时 primary 是 `LLMStructuredParser`（`RuleParser.classify` 正则判类型 → 快递/行程/记账字段交 LLM 抽取，收藏走正则抠 URL，快递状态词仍用正则 `detectStatus`），fallback 是 `LLMTodoParser`；未配 LLM 时 primary 退回纯正则 `RuleParser`，保证无 Key/断网时链路可用。`RuleParser` 的结构化代码（`extractPackage`/`extractTrip`/`extractExpense`）不删——是降级路径，也是 `RealSMSTests` 的测试基线。**截图入口另有 `LLM/ScreenParser.swift`**：一屏 OCR 脏文本常同时含多条多类，它用一个 prompt 一次抽出快递/行程/待办/记账四类数组返回 `.mixed`，与短信入口的「整段归一类」`LLMStructuredParser` 并列。
3. **入库汇聚点**：`OmnyApp/Omny/Services/Ingestor.swift` 是所有入口（短信快捷指令、截图 OCR、分享、手动）的唯一入库通道。关键行为：快递按单号/尾号合并且状态只前进不回退；记账按「单号精确 / 金额+时间窗±10min+尾号或商户 模糊」去重，入库后异步补两级分类（手动记账 `addManualExpense` 例外：尊重用户输入——不解析、不去重、不异步覆盖分类）；低置信度或未识别条目标记 `needsReview` 进"需处理"；收藏入库后异步补标题再 LLM 打标（顺序影响打标准确率）。
4. **分享扩展中转**：扩展进程受限，`OmnyShare` 只把内容写进 App Group 的 JSON 队列（`Shared/SharedInbox.swift`，编入两个 target），解析入库全部回主 App 前台时 drain 完成。
5. **快捷指令入口**：`OmnyApp/Omny/Intents/OmnyIntents.swift` 的 App Intents（「解析文本」「屏幕识别」，后者 struct 名仍为 `RecognizeTodoIntent`，通用识别四类）是短信自动化和截图流程的进入点。
6. **滴答同步**：`OmnyCore/Sources/OmnyCore/Dida/` 的 `DidaSyncEngine` 以 `SyncableTodo` 快照与 SwiftData 解耦（App 层转换）。策略：本地脏标记（`needsPush`/`deletedLocally`）优先推送，其余以远端为准；Open API 无增量接口，拉取为绑定清单的全量轮询。仅 `source == .dida` 的待办参与同步。
7. **LLM 层**：`OmnyCore/Sources/OmnyCore/LLM/` 支持 Claude / OpenAI 兼容两种协议切换（设置页配置）。`LLMClient` 是唯一的请求底座（协议分派、结构化输出参数 400 时自动降级重试、代码围栏剥离、宽容的 ISO 日期解析），各调用方 `LLMStructuredParser`（短信整段结构化）/ `ScreenParser`（一屏多类）/ `LLMTodoParser`（待办 fallback）/ `LLMTagClassifier`（收藏打标）/ `LLMExpenseCategorizer`（记账两级分类）只提供各自的提示词与 JSON Schema。`LLMTagClassifier`／`LLMExpenseCategorizer` 都用 enum schema 限制 LLM 只能从用户配置的池里挑选（记账把「大类/细分」拍平成 `"餐饮/午餐"` 进 enum，锁死合法组合）。

## 分支与 CI（本节为 CI 规则的权威源，其他文档引用此处）

- 维护者在 `main`，合并走 PR；Windows 协作者固定用 `dev-zhanghaha` 分支。
- **`.github/workflows/ci.yml`**：所有 push / PR 都在 Linux 跑 OmnyCore 测试（`core-linux`）；App 编译 + 未签名 ipa（`app-macos`）**改为仅手动触发**（Actions 页 Run workflow），push 不再自动出包——真机验证已由 TestFlight 工作流接管（2026-07-12 起），此 job 仅留作临时验证编译，省 10 倍计费的 macOS 分钟。
- **`.github/workflows/testflight.yml`**：打 `tf-*` tag 或手动触发即云端归档上传 TestFlight，约 4 分钟；构建号 CI 自动生成（`run_number`+偏移，不撞号），签名走 ASC API Key 云签名，协作者无需 Apple 凭据。用法与踩坑见 `docs/testflight-release.md`。

## 设计原则（改代码时遵守）

- 所有入口的信息先落成同一个 `InboxItem`；判断「是什么」靠正则（免费、离线、可穷举），抽取「具体字段」靠 LLM（格式变体不可穷举）；未配 LLM 时整体退回纯正则。
- 新增短信解析规则时，把真实短信脱敏后作为测试用例加进 `OmnyCore/Tests/OmnyCoreTests/`（参考 `RealSMSTests.swift`）。
- 快递状态由短信措辞推断（在途→派送中→待取→已签收），不接物流查询 API。
- `TODO.md` 记录当前进行中的任务与设计定论，动手前先看。
