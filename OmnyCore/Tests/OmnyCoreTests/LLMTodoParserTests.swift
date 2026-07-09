import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import OmnyCore

final class LLMTodoParserTests: XCTestCase {

    // MARK: Claude 协议

    func testClaudeRequestShape() async throws {
        let transport = MockTransport { _ in
            (Data(#"{"content":[{"type":"text","text":"{\"todos\":[]}"}]}"#.utf8), 200)
        }
        let parser = LLMTodoParser(config: .claude(apiKey: "sk-test"), transport: transport)
        _ = try await parser.parse("随便一段话")

        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")

        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        XCTAssertEqual(body?["model"] as? String, "claude-opus-4-8")
        let format = ((body?["output_config"] as? [String: Any])?["format"]) as? [String: Any]
        XCTAssertEqual(format?["type"] as? String, "json_schema")
        XCTAssertEqual((body?["system"] as? String)?.contains("{TODAY}"), false, "日期占位符应被替换")
    }

    func testClaudeExtractsTodos() async throws {
        let transport = MockTransport { _ in
            let inner = #"{"todos":[{"title":"把周报发给老板","due":"2026-07-09T15:00:00+08:00"},{"title":"预约体检","due":null}]}"#
            let envelope = try! JSONSerialization.data(withJSONObject: [
                "content": [["type": "text", "text": inner]],
                "stop_reason": "end_turn",
            ])
            return (envelope, 200)
        }
        let parser = LLMTodoParser(config: .claude(apiKey: "sk-test"), transport: transport)
        let result = try await parser.parse("会议纪要截图OCR文字…明天下午三点前把周报发给老板…记得预约体检…")

        guard case .todos(let todos) = try XCTUnwrap(result).payload else { return XCTFail() }
        XCTAssertEqual(todos.count, 2)
        XCTAssertEqual(todos[0].title, "把周报发给老板")
        XCTAssertEqual(todos[0].due?.day, 9)
        XCTAssertNil(todos[1].due)
    }

    // MARK: OpenAI 兼容协议

    func testOpenAIRequestShape() async throws {
        let transport = MockTransport { _ in
            (Data(#"{"choices":[{"message":{"content":"{\"todos\":[]}"}}]}"#.utf8), 200)
        }
        let config = LLMConfig.openAICompatible(
            baseURL: URL(string: "https://my-proxy.example.com")!,
            apiKey: "sk-proxy", model: "gpt-4o-mini")
        let parser = LLMTodoParser(config: config, transport: transport)
        _ = try await parser.parse("随便一段话")

        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://my-proxy.example.com/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-proxy")

        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        XCTAssertEqual(body?["model"] as? String, "gpt-4o-mini")
        let responseFormat = body?["response_format"] as? [String: Any]
        XCTAssertEqual(responseFormat?["type"] as? String, "json_object")
        let messages = body?["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.first?["role"] as? String, "system")
    }

    func testOpenAIExtractsTodos() async throws {
        let transport = MockTransport { _ in
            let inner = #"{"todos":[{"title":"给妈妈买生日礼物","due":null}]}"#
            let envelope = try! JSONSerialization.data(withJSONObject: [
                "choices": [["message": ["role": "assistant", "content": inner]]],
            ])
            return (envelope, 200)
        }
        let config = LLMConfig.openAICompatible(
            baseURL: URL(string: "https://api.openai.com")!,
            apiKey: "sk", model: "gpt-4o")
        let parser = LLMTodoParser(config: config, transport: transport)
        let result = try await parser.parse("下周之前给妈妈买生日礼物别忘了")

        guard case .todos(let todos) = try XCTUnwrap(result).payload else { return XCTFail() }
        XCTAssertEqual(todos.first?.title, "给妈妈买生日礼物")
    }

    // MARK: 通用行为

    func testEmptyTodosReturnsNil() async throws {
        let transport = MockTransport { _ in
            (Data(#"{"content":[{"type":"text","text":"{\"todos\":[]}"}]}"#.utf8), 200)
        }
        let parser = LLMTodoParser(config: .claude(apiKey: "sk"), transport: transport)
        let result = try await parser.parse("这段文本里没有任何待办")
        XCTAssertNil(result, "没有待办时返回 nil，入口层落为未分类条目")
    }

    func testAPIErrorPropagates() async throws {
        let transport = MockTransport { _ in (Data("rate limited".utf8), 429) }
        let parser = LLMTodoParser(config: .claude(apiKey: "sk"), transport: transport)
        do {
            _ = try await parser.parse("some text")
            XCTFail("应抛错")
        } catch LLMParseError.httpError(let status, _) {
            XCTAssertEqual(status, 429)
        }
    }

    func testPipelineIntegration() async throws {
        // 规则引擎不认识的自由文本 → 落到 LLM 提取
        let transport = MockTransport { _ in
            let inner = #"{"todos":[{"title":"给妈妈买生日礼物","due":null}]}"#
            let envelope = try! JSONSerialization.data(withJSONObject: [
                "content": [["type": "text", "text": inner]],
            ])
            return (envelope, 200)
        }
        let pipeline = ParserPipeline(
            primary: RuleParser(),
            fallback: LLMTodoParser(config: .claude(apiKey: "sk"), transport: transport))
        let result = try await pipeline.parse("下周之前给妈妈买生日礼物别忘了")
        guard case .todos(let todos) = try XCTUnwrap(result).payload else { return XCTFail() }
        XCTAssertEqual(todos.first?.title, "给妈妈买生日礼物")
    }
}
