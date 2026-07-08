# TODO

## 2026-07-10 — 快捷指令导入接线

### 我（用户）要做
- [ ] 编辑好「解析文本」快捷指令流程 → 分享 → 拷贝 iCloud 链接
- [ ] 编辑好「截图记忆 / 识别待办」快捷指令流程（最简：截屏 → 识别待办 → 显示结果，**不加菜单选择补充方式**）→ 拷贝 iCloud 链接
- [ ] 把两条链接发给 Claude

### Claude 拿到链接后要做
- [ ] 用「解析文本」链接替换 `OmnyApp/Omny/Views/SettingsView.swift` 里的占位 `shortcutImportURL`（当前 `https://www.icloud.com/shortcuts/REPLACE_ME`）
- [ ] 为「识别待办」加第二个导入按钮 + 手动触发引导（背面轻点 / 控制中心，**iOS 无"截屏就运行"自动化触发器**）

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
- [x] SettingsView 加「快捷指令」Section：「解析文本」导入按钮（占位链接）+ 两步图文引导

### 设计定论（备忘）
- App Intent 当「收纳箱」，快捷指令用内置动作抓上下文。
- 截图流程参考 Yore App（`c.team.Yore.SaveYore`）：快捷指令内置 `截屏` 抓当前屏 → 喂 `RecognizeTodoIntent`，无需用户先手动截图。
- `RecognizeTodoIntent` 保留 `image` 参数即可；`note` 参数已决定不加。
