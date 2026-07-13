# 发布到 TestFlight（命令行全流程）

把 `Omny` 打包上传到 TestFlight 的可复用流程。**现已首选 CI 自动发布**（见下节），本地命令行流程作为 CI 不可用时的备用路径，全程不依赖 Xcode GUI。
2026-07-10 首次跑通（build 3）；此后 CI 自动发布上线，构建号交 CI 管理，已复跑至 **build 19**，流程与命令保持有效。

## GitHub Actions 自动发布（推荐）

本地流程已搬到 CI（`.github/workflows/testflight.yml`），**构建号由 CI 自动生成**
（工作流运行序号 + 偏移量，唯一且递增），发布不用改 `project.yml`、不用协调构建号，打个 tag 就行：

```sh
# 方式一：打 tag（tf- 开头即可，名字随意，建议带日期）
git tag tf-20260712 && git push origin tf-20260712

# 方式二：Actions 页面手动 Run workflow（可选填 build_number 强制覆盖自动号）
gh workflow run testflight.yml --ref <分支> -f build_number=<构建号>
```

实际用的构建号看运行页面的 Summary。协作者只需有仓库 push 权限即可触发，无需任何 Apple 凭据。
签名用 ASC API Key 云签名，无需导出证书。依赖 4 个仓库 Secrets（见 workflow 文件头部注释）；
**改动 `Secrets.swift` 后要同步更新 Secret**：`base64 -i OmnyApp/Omny/Services/Secrets.swift | gh secret set OMNY_SECRETS_SWIFT_B64`。
私有仓库 macOS runner 分钟按 10 倍计费，实测一次发布约 4 分钟（计费约 40 分钟）。

以下为本地手动流程（CI 不可用时的备用路径）。⚠️ 构建号已交给 CI 管理（`run_number + BUILD_OFFSET`），
本地发布前先查 TestFlight 当前最大构建号，且发完后 CI 的自动号可能落在后面导致 409——尽量别混用两条路。

## 前置条件（一次性）

- **付费 Apple Developer Program 会员**（免费 Apple ID 传不了 TestFlight，只能真机侧载 7 天）。
- App 已在 **App Store Connect** 注册（bundle `xin.codgi.omny`，App ID `6789214684`）。
- **App Store Connect API Key**（免密上传 + 自动签发分发证书都靠它）：
  ASC → Users and Access → Integrations → App Store Connect API → **+** 生成，角色 **App Manager** 或 Admin。
  记下 **Issuer ID**（页面顶部 UUID）和 **Key ID**（10 位），下载 `AuthKey_<KeyID>.p8`（**只能下一次**）。
  放到工具默认搜索位置，之后所有命令自动识别：
  ```sh
  mkdir -p ~/.appstoreconnect/private_keys
  mv ~/Downloads/AuthKey_*.p8 ~/.appstoreconnect/private_keys/
  ```
  ⚠️ `.p8` 有发布权限，切勿提交（`.gitignore` 已含 `AuthKey_*.p8`）。

## 关键参数

| 项 | 值 |
|---|---|
| Team ID | `46SC6UDH48`（付费 team；本机若只有个人 team `HW68X549S7` 的开发证书是不够的） |
| Scheme | **`Omny`**（不是 `OmnyShare`！archive 错 scheme 是常见坑） |
| 主 App bundle | `xin.codgi.omny` |
| 扩展 bundle | `xin.codgi.omny.share` |
| App Group | `group.xin.codgi.omny` |
| 产物目录 | **`~/OmnyBuild`**（必须在 iCloud 同步目录外，否则 codesign 报 detritus，见 CLAUDE.md 陷阱） |

分发证书 / App Store 描述文件**不用手动建** —— `xcodebuild ... -allowProvisioningUpdates` 带上 API Key 授权会自动签发。

## 流程

先设几个变量（换成自己的 Key）：

```sh
export ASC_KEY=UJHU7T46A7           # Key ID
export ASC_ISSUER=<你的 Issuer ID>  # ASC Integrations 页顶部 UUID
export ASC_P8=~/.appstoreconnect/private_keys/AuthKey_${ASC_KEY}.p8
export AUTH="-allowProvisioningUpdates -authenticationKeyPath $ASC_P8 -authenticationKeyID $ASC_KEY -authenticationKeyIssuerID $ASC_ISSUER"
```

**0. 升构建号**（TestFlight 里 build 号必须唯一且递增，重复会 409）。改 `OmnyApp/project.yml` 里**两处** `CURRENT_PROJECT_VERSION`（主 App + OmnyShare，保持一致），然后重新生成工程：

```sh
cd OmnyApp && xcodegen generate && cd ..
```

**1. 校验 Key 能连上 ASC**（顺带确认 App 已注册）：

```sh
xcrun altool --list-apps --apiKey $ASC_KEY --apiIssuer $ASC_ISSUER
```

**2. 归档**（scheme `Omny`，产物在 `~/OmnyBuild`）：

```sh
xcodebuild archive \
  -project OmnyApp/Omny.xcodeproj -scheme Omny -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath ~/OmnyBuild/Omny.xcarchive -derivedDataPath ~/OmnyBuild/DerivedData $AUTH
```
> 归档阶段用**开发证书**签是正常的，分发重签在下一步导出时发生。

**3. 导出 App Store 签名的 ipa**（这一步自动创建 Apple Distribution 证书 + 用分发描述文件重签）：

```sh
xcodebuild -exportArchive \
  -archivePath ~/OmnyBuild/Omny.xcarchive -exportPath ~/OmnyBuild/export \
  -exportOptionsPlist docs/ExportOptions.plist $AUTH
```

`docs/ExportOptions.plist` 内容：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>          <string>app-store-connect</string>
    <key>teamID</key>          <string>46SC6UDH48</string>
    <key>signingStyle</key>    <string>automatic</string>
    <key>uploadSymbols</key>   <true/>
    <key>destination</key>     <string>export</string>
    <key>manageAppVersionAndBuildNumber</key> <false/>
</dict>
</plist>
```

**4. 预校验（可选但推荐，能在真上传前抓错）→ 上传**：

```sh
xcrun altool --validate-app -f ~/OmnyBuild/export/Omny.ipa -t ios --apiKey $ASC_KEY --apiIssuer $ASC_ISSUER
xcrun altool --upload-app   -f ~/OmnyBuild/export/Omny.ipa -t ios --apiKey $ASC_KEY --apiIssuer $ASC_ISSUER
```

看到 `UPLOAD SUCCEEDED with no errors` 即成功。ASC 处理 5~15 分钟（会发邮件），处理完在 TestFlight 分发。

## 踩过的坑

- **`409 ... bundle version must be higher than the previously uploaded version`**：build 号重复。回到步骤 0 升 `CURRENT_PROJECT_VERSION` 重来。预校验（step 4 的 `--validate-app`）能提前发现，别等真上传。
- **`90473 CFBundleVersion/CFBundleShortVersionString Mismatch`（扩展与主 App 版本不一致）**：根因是 `OmnyShare` 用实体 `Info.plist`，而 XcodeGen 每次 `generate` 会按 `project.yml` 的 `info.properties` 重写它、默认写死 `1.0`/`1`（主 App 用 `GENERATE_INFOPLIST_FILE` 所以能继承版本，扩展不能）。**修法在 `project.yml`**（不是手改 plist，会被下次 generate 冲掉）：给 OmnyShare 的 `info.properties` 加
  ```yaml
  CFBundleShortVersionString: $(MARKETING_VERSION)
  CFBundleVersion: $(CURRENT_PROJECT_VERSION)
  ```
  这样扩展版本永远跟主 App 同步。已修，正常情况下不会再犯。
- **archive 了错的 scheme**：Xcode GUI 里容易选中 `OmnyShare` 去 archive，产出的是扩展而非 App。命令行固定 `-scheme Omny` 就不会错。
- **codesign 报 detritus**：产物目录必须在 iCloud 同步目录外（`~/OmnyBuild`），见 CLAUDE.md「已知陷阱」。
- **出口合规**：`project.yml` 已声明 `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: NO`（只用 HTTPS，属豁免加密），上传后不会再追问出口合规。
