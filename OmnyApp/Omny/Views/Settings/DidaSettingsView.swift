import SwiftUI
import SwiftData
import WebKit
import OmnyCore

/// 滴答清单二级页：绑定 / 同步清单 / 立即同步 / 解绑。
/// 从旧一级设置页整体迁入（issue #10 问题3 设置页分层），OAuth WebView 一并搬来。
/// 前台同步最小间隔属低频参数，在「高级设置」里调。
struct DidaSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var dida: DidaService
    @Environment(\.modelContext) private var context
    @State private var showDidaAuth = false
    @State private var didaBindError: String?

    var body: some View {
        Form {
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
            } footer: {
                Text("绑定后待办与滴答清单双向同步，自动使用名为 Omny 的清单（没有则创建）。仅滴答来源的待办参与同步。")
            }
        }
        .navigationTitle("滴答清单")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showDidaAuth) {
            didaAuthSheet
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
