# Windows / WSL 开发笔记

记录在 Windows（WSL2）上开发 `OmnyCore` 过程中踩过的坑与关键结论。README 的《Windows 参与开发指南》讲“怎么做”，这里补“为什么”和“出问题怎么办”。

面向对象：在 Windows 上用 WSL2 开发本项目核心层的协作者。

---

## 环境速查

- **WSL2 发行版**：Ubuntu 24.04.4 LTS，装在 **G 盘**（`G:\WSL\Ubuntu`），不占 C 盘。
- **Swift**：用 [swiftly](https://swift.org/install/linux) 管理。项目根 `.swift-version` 锁定版本。
- **项目路径**：WSL 里通过 `/mnt/g/selfSoft/01_GitHub/Omny/omny` 访问 Windows 上的仓库。
- **跑测试**：
  ```bash
  source ~/.local/share/swiftly/env.sh
  cd /mnt/g/selfSoft/01_GitHub/Omny/omny/OmnyCore
  swift test
  ```

---

## 把 WSL 装到非 C 盘（方案：直接导入到目标盘）

C 盘紧张时，别用默认的 `wsl --install -d Ubuntu`（发行版数据会落在 C 盘）。改用手动导入：

```powershell
# 1. 只装 WSL 引擎，不装任何发行版（管理员 PowerShell）
wsl --install --no-distribution
# 需要重启则重启

# 2. 下载 Ubuntu rootfs 到目标盘（.wsl 文件本质是 tar 归档）
#    官方直链见 https://github.com/microsoft/WSL/blob/master/distributions/DistributionInfo.json
#    本次用的是 Ubuntu 24.04.4：
#    https://releases.ubuntu.com/24.04.4/ubuntu-24.04.4-wsl-amd64.wsl

# 3. 导入到目标盘（数据从此都在 G 盘）
wsl --import Ubuntu "G:\WSL\Ubuntu" "G:\WSL\ubuntu-24.04.wsl" --version 2

# 4. 建普通用户并设为默认（--import 的发行版默认 root 登录）
wsl -d Ubuntu -u root useradd -m -s /bin/bash -G sudo <你的用户名>
wsl -d Ubuntu -u root bash -c "echo '<用户名>:<密码>' | chpasswd"
wsl -d Ubuntu -u root bash -c "printf '[user]\ndefault=<用户名>\n' > /etc/wsl.conf"
wsl --terminate Ubuntu   # 重启发行版让默认用户生效
```

> 引擎本体仍在 C 盘系统目录（几十 MB，很小）；会随开发变大的发行版数据（那个 `ext4.vhdx`）全在 G 盘。

---

## 坑 1：Linux 上网络类型要显式 `import FoundationNetworking`（重要）

**现象**：`swift test` 在 Linux 上报一堆看似无关的错误——
- `cannot find type 'URLRequest' in scope`
- `'HTTPURLResponse' is unavailable: This type has moved to the FoundationNetworking module. Import that module to use it.`
- 以及连带的 `type of expression is ambiguous`、`generic parameter 'T' could not be inferred`（这些是级联错误，别被带偏）

**根因**：Apple 平台上 `import Foundation` 就包含了 `URLRequest`/`HTTPURLResponse`/`URLSession` 等网络类型；但 **Linux 的 Foundation 把这些拆到了独立的 `FoundationNetworking` 模块**，必须显式导入。

**修法**：凡是用到网络类型的文件（含**测试文件**），顶部都要按跨平台写法导入：
```swift
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
```
`#if canImport` 保证 Apple 平台（没有这个模块）也能编译。

**教训**：生产代码（`DidaClient.swift`、`LLMTodoParser.swift`）当初写对了，但两个测试文件（`DidaSyncTests.swift`、`LLMTodoParserTests.swift`）漏了，只有 `import XCTest`。在 macOS/Xcode 上因为 Foundation 自动全含，漏了也没暴露；一到 Linux 就崩。**在 Windows/WSL 上开发的价值之一，就是能提前抓到这类 macOS 掩盖的跨平台问题。**

---

## 坑 2：切换 Swift 版本后必须清 `.build`

**现象**：`swiftly use` 换了版本后跑 `swift test` 报
`module compiled with Swift X cannot be imported by the Swift Y compiler`。

**根因**：`.build/` 里缓存着旧版本编译的 `.swiftmodule`，新编译器不认。

**修法**：
```bash
rm -rf .build && swift test
```

---

## 坑 3：`swift test` 与 Swift 版本无关的“类型推断”错，先怀疑 import

调试顺序建议：遇到大批编译错误，**先用 `swift build --build-tests 2>&1 | grep error: | sort -u` 一次性看全所有错误**，别逐个修——很多是级联的，根因往往是某个基础类型/模块没导入（见坑 1）。逐个改会“撞地鼠”，越改越乱。

---

## 关于 `.swift-version`

项目根的 `.swift-version` 由 swiftly 写入，进入目录会自动切到该版本。好处是团队用 swiftly 时自动对齐；注意它会影响所有用 swiftly 的协作者（macOS 上的 Xcode 不读它，无影响）。

---

## 已验证

- Ubuntu 24.04.4 LTS on WSL2（G 盘），Swift 由 swiftly 管理。
- `OmnyCore` 全部单测在 Linux 通过（补 import 修复后）。测试量随模块增长（记账/识屏/计算器等），以 `swift test` 实跑数为准，截至 2026-07 为 146。
