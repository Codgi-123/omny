import SwiftUI
import OmnyCore

/// LLM 解析引擎二级页：协议 / Base URL / Key / 模型 / 连通性测试。
/// 从旧一级设置页整体迁入（issue #10 问题3 设置页分层）。
/// maxTokens / 请求超时属低频参数，在「高级设置」里调。
struct LLMSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
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
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let result = llmTestResult {
                        Text(result)
                            .foregroundStyle(llmTestSucceeded ? Theme.green : Theme.red)
                    }
                    Text("用于短信/屏幕识别（快递/行程/待办/记账结构化）和收藏自动打标。填域名即可，路径按协议自动补全（Claude → /v1/messages，OpenAI → /v1/chat/completions）。留空 Key 则只用规则引擎。")
                }
            }
        }
        .navigationTitle("LLM 解析引擎")
        .navigationBarTitleDisplayMode(.inline)
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
}
