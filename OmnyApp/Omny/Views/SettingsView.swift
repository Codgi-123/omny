import SwiftUI
import SwiftData
import WebKit
import OmnyCore

struct SettingsView: View {
    /// 「解析文本」完整流程的 iCloud 分享链接。
    /// 在快捷指令 App 里打开该流程 → 分享 → 拷贝 iCloud 链接，替换下面这行即可。
    static let shortcutImportURL = URL(string: "https://www.icloud.com/shortcuts/78b9cbce584647c293b7e2b61c8d0f37")!

    /// 「截图记忆 / 识别待办」流程的 iCloud 分享链接。
    static let screenshotShortcutImportURL = URL(string: "https://www.icloud.com/shortcuts/f37dc8b6ef9f4569a38f1abdad4f5a8b")!

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var dida: DidaService
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @State private var showDidaAuth = false
    @State private var didaBindError: String?
    @State private var llmTesting = false
    @State private var llmTestSucceeded = false
    @State private var llmTestResult: String?

    var body: some View {
        Form {
            Section {
                Picker("接口协议", selection: $settings.llmProtocol) {
                    Text("Claude").tag(LLMProtocol.claude)
                    Text("OpenAI 兼容").tag(LLMProtocol.openai)
                }
                TextField("Base URL", text: $settings.llmBaseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("API Key", text: $settings.llmAPIKey)
                TextField("模型", text: $settings.llmModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    testLLM()
                } label: {
                    HStack {
                        Label("测试连通性", systemImage: "bolt")
                        if llmTesting { Spacer(); ProgressView().controlSize(.small) }
                    }
                }
                .disabled(llmTesting || settings.llmConfig == nil)
            } header: {
                Text("LLM 解析引擎")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let result = llmTestResult {
                        Text(result)
                            .foregroundStyle(llmTestSucceeded ? Theme.green : Theme.red)
                    }
                    Text("用于截图待办提取和收藏自动打标。填域名即可，路径按协议自动补全（Claude → /v1/messages，OpenAI → /v1/chat/completions）。留空 Key 则只用规则引擎。")
                }
            }

            Section {
                if settings.didaBound {
                    LabeledContent("状态", value: "已绑定")
                    LabeledContent("同步清单", value: settings.didaProjectName ?? "-")
                    if let last = settings.didaLastSync {
                        LabeledContent("上次同步", value: last.formatted())
                    }
                    Button("立即同步") {
                        Task { await dida.syncNow(context: context) }
                    }
                    Button("解绑", role: .destructive) { dida.unbind() }
                } else {
                    Button("绑定滴答账号") { showDidaAuth = true }
                }
                if let error = didaBindError ?? dida.lastError {
                    Text(error).font(.footnote).foregroundStyle(Theme.red)
                }
            } header: {
                Text("滴答清单")
            } footer: {
                Text("绑定后待办与滴答清单双向同步，自动使用名为 Omny 的清单（没有则创建）。")
            }

            Section("行程") {
                Toggle("自动写入系统日历", isOn: $settings.autoAddToCalendar)
            }

            Section {
                NavigationLink {
                    TagManageView()
                } label: {
                    LabeledContent("收藏标签", value: "\(settings.bookmarkTags.count) 个")
                }
            } header: {
                Text("收藏")
            } footer: {
                Text("分享进来的内容由上方配置的 LLM 从这批标签里自动挑选打标；未配置 LLM 时收藏照常入库，标签手动补。")
            }

            Section {
                Button {
                    openURL(Self.shortcutImportURL)
                } label: {
                    Label("导入「解析文本」快捷指令", systemImage: "square.and.arrow.down")
                }
            } header: {
                Text("快捷指令 · 解析文本")
            } footer: {
                Text("""
                第 1 步：点上方按钮，在弹出的页面点「添加快捷指令」，整套流程即导入你的快捷指令库。
                第 2 步：打开快捷指令 App →「自动化」→ 新建 →「信息」→ 收到信息时「立即运行」→ 运行刚导入的「解析文本」，输入选「信息内容」。
                之后每条短信自动解析入库，无需手动操作。
                """)
            }

            Section {
                Button {
                    openURL(Self.screenshotShortcutImportURL)
                } label: {
                    Label("导入「识别待办」快捷指令", systemImage: "square.and.arrow.down")
                }
            } header: {
                Text("快捷指令 · 识别待办")
            } footer: {
                Text("""
                第 1 步：点上方按钮，在弹出的页面点「添加快捷指令」。
                第 2 步：手动触发运行——推荐设为「轻点背面两下」（设置 → 辅助功能 → 触控 → 轻点背面）或加进控制中心。iOS 没有「截屏即运行」的自动化触发器，需手动唤起。
                运行后自动截屏并识别待办，结果进「需处理内容」等你确认。
                """)
            }

            Section("数据") {
                NavigationLink("需处理内容") { ReviewView() }
            }

            Section("关于") {
                LabeledContent("版本", value: "0.1.0")
            }
        }
        .navigationTitle("设置")
        .sheet(isPresented: $showDidaAuth) {
            didaAuthSheet
        }
    }

    /// LLM 连通性测试：跑一次和收藏打标完全相同的请求链路，
    /// 成功给出试打标结果，失败原样展示 HTTP 状态/响应（方便定位 Key、URL、协议问题）。
    private func testLLM() {
        guard let config = settings.llmConfig else { return }
        llmTesting = true
        llmTestResult = nil
        Task {
            let candidates = settings.bookmarkTags.isEmpty
                ? AppSettings.defaultBookmarkTags : settings.bookmarkTags
            do {
                let tags = try await LLMTagClassifier(config: config)
                    .classify("一篇介绍 SwiftUI 动画实现技巧的技术博客文章", candidates: candidates)
                llmTestSucceeded = true
                llmTestResult = tags.isEmpty
                    ? "✓ 连接正常（模型未选出标签）"
                    : "✓ 连接正常，试打标结果：\(tags.joined(separator: "、"))"
            } catch {
                llmTestSucceeded = false
                llmTestResult = "✗ \(Ingestor.describeLLMError(error))"
            }
            llmTesting = false
        }
    }

    private var didaAuthSheet: some View {
        DidaAuthSheet { code in
            showDidaAuth = false
            Task {
                do {
                    try await dida.completeBinding(code: code)
                    didaBindError = nil
                } catch {
                    didaBindError = "绑定失败：\(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - 滴答 OAuth 授权页（内嵌 WebView，拦截 localhost 回跳取 code）

struct DidaAuthSheet: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            DidaAuthWebView(url: DidaService.shared.authorizeURL, onCode: onCode)
                .navigationTitle("绑定滴答清单")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                }
        }
    }
}

struct DidaAuthWebView: UIViewRepresentable {
    let url: URL
    let onCode: (String) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onCode: (String) -> Void

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // 拦截 http://localhost/omny/oauth?code=... 回跳，取走 code，不真的加载
            if let url = navigationAction.request.url,
               url.host() == "localhost", url.path == "/omny/oauth",
               let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                   .queryItems?.first(where: { $0.name == "code" })?.value {
                decisionHandler(.cancel)
                onCode(code)
                return
            }
            decisionHandler(.allow)
        }
    }
}
