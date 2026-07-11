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

### 候选方向（已调研、未拍板）
- **记账**（2026-07-09 调研）：定位「捕获层 + 轻账本」，新增 `expense` kind 复用现有管线，不做账户体系/预算/报表。三层入口：① 银行动账短信走现有快捷指令通道（常用卡提醒建议开成短信，可覆盖大部分绑卡支付）；② 支付成功页截图 OCR（同 Yore 式截屏流程，钱迹 iOS 同款方案）；③ 微信/支付宝官方 CSV 账单导入兜底全量（唯一含零钱/花呗的权威数据源，官方交易单号做合并主键，吸收前两层的重复条目）。消费分类复用 `LLMTagClassifier` 的 enum-schema 思路。注意：iOS 拿不到微信/支付宝实时支付数据是系统级限制，全行业无解，不必追求 Android 式全自动。UI 侧 5 个 tab 已满，倾向快递+行程合并腾位。
