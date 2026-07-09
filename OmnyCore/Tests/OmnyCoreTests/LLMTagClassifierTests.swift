import XCTest
@testable import OmnyCore

final class LLMTagClassifierTests: XCTestCase {

    let candidates = ["技术", "资讯", "视频", "购物", "灵感"]

    // MARK: Claude 协议

    func testClaudeRequestShape() async throws {
        let transport = MockTransport { _ in
            (Data(#"{"content":[{"type":"text","text":"{\"tags\":[]}"}]}"#.utf8), 200)
        }
        let classifier = LLMTagClassifier(config: .claude(apiKey: "sk-test"), transport: transport)
        _ = try await classifier.classify("SwiftData 迁移踩坑记录 https://example.com/post",
                                          candidates: candidates)

        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")

        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        let system = try XCTUnwrap(body?["system"] as? String)
        XCTAssertTrue(system.contains("技术"), "候选标签应写进提示词")
        XCTAssertFalse(system.contains("{TAGS}"), "占位符应被替换")
        XCTAssertFalse(system.contains("{MAX}"), "占位符应被替换")

        // structured outputs 的 enum 应锁死在候选列表
        let format = ((body?["output_config"] as? [String: Any])?["format"]) as? [String: Any]
        XCTAssertEqual(format?["type"] as? String, "json_schema")
        let schema = format?["schema"] as? [String: Any]
        let tagsProp = (schema?["properties"] as? [String: Any])?["tags"] as? [String: Any]
        let itemEnum = (tagsProp?["items"] as? [String: Any])?["enum"] as? [String]
        XCTAssertEqual(itemEnum, candidates)
    }

    func testClaudeClassifiesTags() async throws {
        let transport = MockTransport { _ in
            (Data(#"{"content":[{"type":"text","text":"{\"tags\":[\"技术\",\"灵感\"]}"}]}"#.utf8), 200)
        }
        let classifier = LLMTagClassifier(config: .claude(apiKey: "sk"), transport: transport)
        let tags = try await classifier.classify("一篇讲 SwiftUI 动画的博客", candidates: candidates)
        XCTAssertEqual(tags, ["技术", "灵感"])
    }

    // MARK: OpenAI 兼容协议

    func testOpenAIRequestShape() async throws {
        let transport = MockTransport { _ in
            (Data(#"{"choices":[{"message":{"content":"{\"tags\":[\"视频\"]}"}}]}"#.utf8), 200)
        }
        let config = LLMConfig.openAICompatible(
            baseURL: URL(string: "https://my-proxy.example.com")!,
            apiKey: "sk-proxy", model: "gpt-4o-mini")
        let classifier = LLMTagClassifier(config: config, transport: transport)
        let tags = try await classifier.classify("B站视频链接", candidates: candidates)

        XCTAssertEqual(tags, ["视频"])
        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://my-proxy.example.com/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-proxy")
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        XCTAssertEqual((body?["response_format"] as? [String: Any])?["type"] as? String, "json_object")
    }

    // MARK: 防越界

    func testFiltersTagsOutsideCandidates() async throws {
        // 模型发明新标签 / 重复 / 超量时，本地兜底过滤
        let transport = MockTransport { _ in
            let inner = #"{"tags":["技术","编程","技术","资讯","视频","灵感"]}"#
            let envelope = try! JSONSerialization.data(withJSONObject: [
                "content": [["type": "text", "text": inner]],
            ])
            return (envelope, 200)
        }
        let classifier = LLMTagClassifier(config: .claude(apiKey: "sk"), transport: transport)
        let tags = try await classifier.classify("随便什么内容", candidates: candidates)
        XCTAssertEqual(tags, ["技术", "资讯", "视频"], "过滤发明标签、去重、截断到 maxTags")
    }

    func testEmptyContentOrCandidatesSkipsRequest() async throws {
        let transport = MockTransport { _ in
            XCTFail("不应发请求")
            return (Data(), 200)
        }
        let classifier = LLMTagClassifier(config: .claude(apiKey: "sk"), transport: transport)
        let noContent = try await classifier.classify("   ", candidates: candidates)
        XCTAssertEqual(noContent, [])
        let noCandidates = try await classifier.classify("内容", candidates: [])
        XCTAssertEqual(noCandidates, [])
    }

    func testAPIErrorPropagates() async throws {
        let transport = MockTransport { _ in (Data("rate limited".utf8), 429) }
        let classifier = LLMTagClassifier(config: .claude(apiKey: "sk"), transport: transport)
        do {
            _ = try await classifier.classify("内容", candidates: candidates)
            XCTFail("应抛错")
        } catch LLMParseError.httpError(let status, _) {
            XCTAssertEqual(status, 429)
        }
    }

    // MARK: 结构化输出降级（端点不支持 json_schema / json_object 时）

    func testFallsBackWithoutStructuredOutputOn400() async throws {
        // 第一次请求（带 output_config）400 → 自动重试不带该参数的请求
        let transport = MockTransport { request in
            let body = try! JSONSerialization.jsonObject(
                with: request.httpBody!) as! [String: Any]
            if body["output_config"] != nil {
                return (Data(#"{"error":"unknown parameter: output_config"}"#.utf8), 400)
            }
            // 降级请求：模型把 JSON 包在代码围栏里也要能解析
            let inner = "```json\n{\"tags\":[\"技术\"]}\n```"
            let envelope = try! JSONSerialization.data(withJSONObject: [
                "content": [["type": "text", "text": inner]],
            ])
            return (envelope, 200)
        }
        let classifier = LLMTagClassifier(config: .claude(apiKey: "sk"), transport: transport)
        let tags = try await classifier.classify("SwiftUI 博客", candidates: candidates)

        XCTAssertEqual(tags, ["技术"])
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 2, "400 后应重试一次")
        let retryBody = try JSONSerialization.jsonObject(
            with: XCTUnwrap(requests.last?.httpBody)) as? [String: Any]
        XCTAssertNil(retryBody?["output_config"], "重试请求不应带结构化输出参数")
    }

    func testOpenAIFallsBackWithoutResponseFormat() async throws {
        let transport = MockTransport { request in
            let body = try! JSONSerialization.jsonObject(
                with: request.httpBody!) as! [String: Any]
            if body["response_format"] != nil {
                return (Data(#"{"error":"response_format is not supported"}"#.utf8), 400)
            }
            return (Data(#"{"choices":[{"message":{"content":"{\"tags\":[\"视频\"]}"}}]}"#.utf8), 200)
        }
        let config = LLMConfig.openAICompatible(
            baseURL: URL(string: "https://my-proxy.example.com")!,
            apiKey: "sk", model: "some-model")
        let classifier = LLMTagClassifier(config: config, transport: transport)
        let tags = try await classifier.classify("B站视频", candidates: candidates)
        XCTAssertEqual(tags, ["视频"])
    }

    func testBothAttemptsFailingThrowsSecondError() async throws {
        // 两次都 400（说明不是结构化输出的问题，比如模型名错）→ 抛第二次的错误
        let transport = MockTransport { _ in (Data("model not found".utf8), 400) }
        let classifier = LLMTagClassifier(config: .claude(apiKey: "sk"), transport: transport)
        do {
            _ = try await classifier.classify("内容", candidates: candidates)
            XCTFail("应抛错")
        } catch LLMParseError.httpError(let status, let body) {
            XCTAssertEqual(status, 400)
            XCTAssertEqual(body, "model not found")
        }
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 2)
    }
}
