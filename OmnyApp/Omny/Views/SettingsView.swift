import SwiftUI
import SwiftData
import WebKit
import OmnyCore

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var dida: DidaService
    @Environment(\.modelContext) private var context
    @State private var showDidaAuth = false
    @State private var didaBindError: String?

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
            } header: {
                Text("LLM 解析引擎")
            } footer: {
                Text("用于截图待办提取。填域名即可，路径按协议自动补全（Claude → /v1/messages，OpenAI → /v1/chat/completions）。留空 Key 则只用规则引擎。")
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

            Section("数据") {
                NavigationLink("需处理内容") { ReviewView() }
            }

            Section("关于") {
                LabeledContent("版本", value: "0.1.0")
            }
        }
        .navigationTitle("设置")
        .sheet(isPresented: $showDidaAuth) {
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
