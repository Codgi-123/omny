# Omny

个人信息收件箱 iOS App（自用，不上架）。把散落在短信、截图、系统分享里的信息自动解析成结构化条目，统一管理。

| 信息来源 | 进入方式 | 落成什么 |
|---|---|---|
| 短信（驿站/12306/航司） | 快捷指令自动化，收到即解析 | 快递（取件码/状态）、行程（车次/时刻/座位） |
| 截图 | 快捷指令截屏 → App 内 OCR + LLM 提取 | 待办（可勾选确认入库） |
| 系统分享 | 任意 App 分享面板 → 选 Omny（分享扩展） | 收藏（链接/文本，LLM 自动打标） |
| 手动 | App 内添加 | 待办、收藏 |

页面：**今天**（聚合时间线）· **快递** · **行程** · **待办**（与滴答清单双向同步）· **收藏**（tag 筛选/编辑，标签池在设置里管理），外加设置页（LLM 协议/URL/Key/模型、滴答绑定、日历开关、收藏标签）。

## 架构

```
OmnyCore/   纯 Swift 逻辑包，跨平台（macOS / Linux / WSL 均可开发测试）
  ├─ RuleParser           正则引擎：类型分类 + 无 LLM 时的降级结构化（零成本离线）
  ├─ ParserPipeline       primary / fallback 两级解析管线
  ├─ LLMClient            LLM 调用公共底座（Claude / OpenAI 兼容协议可切换，结构化输出降级重试）
  ├─ LLMStructuredParser  分类靠正则、结构化靠 LLM（快递/行程字段抽取，管线 primary）
  ├─ LLMTodoParser        LLM 待办提取（管线 fallback）
  ├─ LLMTagClassifier     LLM 收藏打标（从用户 tag 池挑选，enum schema 防越界）
  └─ Dida*                滴答清单 OAuth + 任务 CRUD + 双向同步引擎

OmnyApp/    SwiftUI 壳（仅 macOS 可编译），XcodeGen 管理工程
  ├─ Omny/             主 App target
  │   ├─ InboxItem     统一条目模型（SwiftData），页面都是按类型过滤的视图
  │   ├─ Ingestor      入库服务：入口 → 解析管线 → 落库（快递按单号合并、收藏自动打标）
  │   ├─ OmnyIntents   App Intents：「解析文本」「屏幕识别」（快捷指令入口）
  │   └─ Views/        五个 tab + 设置 + 需处理 + 收藏标签管理
  ├─ OmnyShare/        分享扩展 target：分享面板抓链接/文本 → App Group 队列
  └─ Shared/           两个 target 共用：SharedInbox（App Group 中转队列）
```

设计原则：**所有入口的信息先落成同一个 `InboxItem`；判类型靠正则（免费、离线、可穷举），抽字段靠 LLM（应对无穷的格式变体），未配 LLM 时退回纯正则**。解析架构的完整说明见 [docs/parsing-architecture.md](docs/parsing-architecture.md)。

## macOS 开发（完整开发）

要求：Xcode 16+（含 iOS 17 SDK）、[XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）。

```sh
git clone git@github.com:Codgi-123/omny.git && cd omny

# 1. 填入密钥（文件已被 .gitignore 排除，向维护者索要真实值）
cp OmnyApp/Secrets.swift.example OmnyApp/Omny/Services/Secrets.swift

# 2. 跑核心层测试
cd OmnyCore && swift test && cd ..

# 3. 生成工程并打开
cd OmnyApp && xcodegen generate && open Omny.xcodeproj
```

真机安装：Xcode 里登录 Apple ID（免费个人团队即可）→ Signing 选自己的 Team → ⌘R。免费证书 7 天过期，重新 ⌘R 一次即可。

## Windows 参与开发指南

iOS 的 UI 层（`OmnyApp/`）只能在 macOS 编译，这是 Apple 的限制。但本项目的核心逻辑全部在跨平台的 `OmnyCore/`，Windows 上可以完整地开发、测试它，并通过 CI 验证 App 层、通过侧载在自己的 iPhone 上运行最新版。环境踩坑与排障记录见 [docs/dev-notes-windows.md](docs/dev-notes-windows.md)。

### 1. 环境搭建（WSL2）

```sh
# Windows 上启用 WSL2 并安装 Ubuntu，然后在 Ubuntu 里：
# 从 https://swift.org/install/linux 安装 Swift 6 工具链，验证：
swift --version

git clone git@github.com:Codgi-123/omny.git && cd omny/OmnyCore
swift test          # 全绿说明环境就绪
```

编辑器推荐 VS Code + 官方 Swift 扩展（连接 WSL 使用），有补全、跳转和调试。

### 2. 你能改什么

- **`OmnyCore/` 的一切**（主战场）：新短信模板的解析规则（把自己手机的真实短信脱敏后加进 `Tests/`）、同步引擎、LLM 提示词与协议适配。改完本地 `swift test` 验证。
- **`OmnyApp/` 的 SwiftUI 代码**：可以写（就是文本），但本地不能编译预览，推上去靠 CI 的 macOS job 验证。小改动可行，大界面改动建议和 Mac 侧协作者结对。

### 3. 分支与 CI 约定

- 维护者在 `main`；Windows 协作者在 **`dev-zhanghaha`** 分支开发（首次：`git checkout -b dev-zhanghaha && git push -u origin dev-zhanghaha`）。
- 每次 push：所有分支都自动跑 OmnyCore 测试（Linux）；**只有 `dev-zhanghaha` 分支**额外在 macOS 上编译 App 并产出未签名 ipa（避免浪费 macOS 计费分钟）。其他分支需要出包时，在 Actions 页面手动 Run workflow。
- 合并回 `main` 走 Pull Request。

### 4. 把最新版装进自己的 iPhone（无需 Mac）

1. GitHub 仓库 → **Actions** → 选最新一次 `dev-zhanghaha` 分支的运行 → 下载 **Omny-unsigned-ipa**。
2. Windows 上安装 [Sideloadly](https://sideloadly.io/)，iPhone 数据线连电脑。
3. 把 ipa 拖进 Sideloadly，填**自己的 Apple ID**（免费账号即可），Start——它会用你的证书重签并安装。
4. 手机上：设置 → 通用 → VPN与设备管理 → 信任自己的开发者证书。
5. 免费证书 7 天过期，重装一次即可；想自动续签可用 AltServer。
6. ipa 里带了分享扩展（PlugIns/OmnyShare.appex），Sideloadly 默认会连同扩展一起重签；如果重签报 App Group 相关错误，在 Advanced Options 里勾选与 app extensions / app groups 相关的签名选项再试。

### 5. 密钥

`cp OmnyApp/Secrets.swift.example OmnyApp/Omny/Services/Secrets.swift`，向维护者索要滴答清单的 client_id / client_secret 填入。**`Secrets.swift` 与 `Secrets.local.json` 永远不要提交**（已在 .gitignore）。LLM 的 API Key 不在代码里——装好 App 后在设置页填。

## CI 一览

| Job | 触发 | 干什么 |
|---|---|---|
| `core-linux` | 所有 push / PR | Ubuntu 容器跑 OmnyCore 全量测试 |
| `app-macos` | `dev-zhanghaha` 分支 push / 手动触发 | macOS 上编译 App + 产出未签名 ipa（artifact 保留 14 天） |

## 已知约定与取舍

- 快递状态由短信措辞推断（在途→派送中→待取→已签收），同单号多条短信按状态只前进合并；不接物流查询 API。
- 滴答同步：本地脏标记优先推送，其余以远端为准；Open API 无增量接口，拉取为全量轮询绑定清单。
- 免费签名装机 7 天有效，是 Apple 对免费账号的限制。
