import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import OmnyCore

/// 带响应头的测试替身：MCP 握手要从响应头里取 Mcp-Session-Id，
/// DidaSyncTests 的 MockTransport 不带头，这里单独做一个。
actor FlightMockTransport: HTTPTransport {
    private(set) var requests: [URLRequest] = []
    private let handler: @Sendable (Int, URLRequest) -> (Data, Int, [String: String])

    init(handler: @escaping @Sendable (Int, URLRequest) -> (Data, Int, [String: String])) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let index = requests.count
        requests.append(request)
        let (data, status, headers) = handler(index, request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: headers)!
        return (data, response)
    }

    func recordedRequests() -> [URLRequest] { requests }
}

final class FlightDynamicsTests: XCTestCase {
    static let sampleFlightJSON = """
    [{"depTerm":"T2","arrCode":"HGH","depZone":"GMT+08:00","arrPlanTime":"2026-07-14 18:45:00",\
    "depCode":"CTU","luggage":"22","depCaclTime":"2026-07-14 16:20:00","arrZone":"GMT+08:00",\
    "localDate":"2026-07-14","state":"延误","arrTerm":"T4","flightNo":"CA4597",\
    "checkIn":{"counter":"R,S,T,U"},"gate":"C12","depPlanTime":"2026-07-14 16:15:00",\
    "arrCaclTime":"2026-07-14 18:50:00","isShare":0,"passenger":1,"tips":""}]
    """

    static func toolEnvelope(_ flightsJSON: String) -> Data {
        let body: [String: Any] = [
            "jsonrpc": "2.0", "id": "1",
            "result": ["content": [["type": "text", "text": flightsJSON]]],
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    static let initEnvelope = Data(
        #"{"jsonrpc":"2.0","id":"1","result":{"protocolVersion":"2025-06-18"}}"#.utf8)

    private func makeClient(_ transport: FlightMockTransport) -> FlightDynamicsClient {
        FlightDynamicsClient(endpoint: URL(string: "https://example.com/mcp")!,
                             apiKey: "sk_test", transport: transport)
    }

    // MARK: 字段映射

    func testParsesFlightFields() async throws {
        let transport = FlightMockTransport { index, _ in
            switch index {
            case 0: (Self.initEnvelope, 200, ["Mcp-Session-Id": "sid-1"])
            case 1: (Data(), 202, [:])
            default: (Self.toolEnvelope(Self.sampleFlightJSON), 200, [:])
            }
        }
        let flights = try await makeClient(transport)
            .fetch([FlightQuery(no: "ca4597", date: "2026-07-14")])

        XCTAssertEqual(flights.count, 1)
        let f = flights[0]
        XCTAssertEqual(f.flightNo, "CA4597")
        XCTAssertEqual(f.key, "CA4597|2026-07-14")
        XCTAssertEqual(f.depCode, "CTU")
        XCTAssertEqual(f.arrCode, "HGH")
        XCTAssertEqual(f.depTerminal, "T2")
        XCTAssertEqual(f.arrTerminal, "T4")
        XCTAssertEqual(f.gate, "C12")
        XCTAssertEqual(f.luggage, "22")
        XCTAssertEqual(f.checkInCounter, "R,S,T,U")
        XCTAssertEqual(f.state, "延误")

        // 时间按 GMT+8 解析：16:15 东八区 = 08:15 UTC
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let dep = utc.dateComponents([.hour, .minute], from: try XCTUnwrap(f.depPlanTime))
        XCTAssertEqual(dep.hour, 8)
        XCTAssertEqual(dep.minute, 15)
        // 预计时间（caclTime）与计划时间是两个字段
        let depEst = utc.dateComponents([.minute], from: try XCTUnwrap(f.depEstimateTime))
        XCTAssertEqual(depEst.minute, 20)
    }

    func testEmptyStringsBecomeNil() throws {
        let json = """
        [{"flightNo":"MU5137","localDate":"2026-07-18","gate":"","luggage":"",\
        "depCode":"SHA","state":"计划","checkIn":{"counter":""}}]
        """
        let flights = try FlightDynamicsClient.parseFlights(from: Self.toolEnvelope(json))
        XCTAssertEqual(flights.count, 1)
        XCTAssertNil(flights[0].gate)
        XCTAssertNil(flights[0].luggage)
        XCTAssertNil(flights[0].checkInCounter)
        XCTAssertNil(flights[0].depPlanTime)
    }

    // MARK: 握手与协议

    func testHandshakeSendsSessionIDAndAuth() async throws {
        let transport = FlightMockTransport { index, _ in
            switch index {
            case 0: (Self.initEnvelope, 200, ["mcp-session-id": "sid-lower"])
            case 1: (Data(), 202, [:])
            default: (Self.toolEnvelope("[]"), 200, [:])
            }
        }
        _ = try await makeClient(transport).fetch([FlightQuery(no: "CA1", date: "2026-07-14")])

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 3)
        // 鉴权头都在
        for request in requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk_test")
        }
        // initialize 不带 session；后续请求回传（响应头键大小写不敏感）
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Mcp-Session-Id"))
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Mcp-Session-Id"), "sid-lower")
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Mcp-Session-Id"), "sid-lower")

        // tools/call 的参数形状
        let body = try JSONSerialization.jsonObject(with: requests[2].httpBody!) as! [String: Any]
        XCTAssertEqual(body["method"] as? String, "tools/call")
        let params = body["params"] as! [String: Any]
        XCTAssertEqual(params["name"] as? String, "dynamic_flight_batch")
        let args = params["arguments"] as! [String: Any]
        let flights = args["flights"] as! [[String: String]]
        XCTAssertEqual(flights, [["no": "CA1", "date": "2026-07-14"]])
    }

    func testBatchesOverTwentySplit() async throws {
        let transport = FlightMockTransport { index, _ in
            switch index {
            case 0: (Self.initEnvelope, 200, [:])
            case 1: (Data(), 202, [:])
            default: (Self.toolEnvelope("[]"), 200, [:])
            }
        }
        let queries = (1...25).map { FlightQuery(no: "CA\($0)", date: "2026-07-14") }
        _ = try await makeClient(transport).fetch(queries)

        let requests = await transport.recordedRequests()
        // initialize + initialized + 两批 tools/call
        XCTAssertEqual(requests.count, 4)
        let counts = try requests[2...].map { request -> Int in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let params = body["params"] as! [String: Any]
            let args = params["arguments"] as! [String: Any]
            return (args["flights"] as! [Any]).count
        }
        XCTAssertEqual(counts, [20, 5])
    }

    // MARK: 响应变体

    func testParsesSSEFramedResponse() throws {
        let envelope = String(decoding: Self.toolEnvelope(Self.sampleFlightJSON), as: UTF8.self)
        let sse = Data("event: message\ndata: \(envelope)\n\n".utf8)
        let flights = try FlightDynamicsClient.parseFlights(from: sse)
        XCTAssertEqual(flights.first?.flightNo, "CA4597")
    }

    func testMCPErrorSurfaces() {
        let error = Data(#"{"jsonrpc":"2.0","id":"1","error":{"code":-32000,"message":"bad key"}}"#.utf8)
        XCTAssertThrowsError(try FlightDynamicsClient.parseFlights(from: error)) { err in
            guard case FlightDynamicsError.mcpError = err else {
                return XCTFail("应抛 mcpError，实际 \(err)")
            }
        }
    }

    func testZoneParsing() {
        XCTAssertEqual(FlightDynamicsClient.RawFlight.parseZone("GMT+08:00")?.secondsFromGMT(), 8 * 3600)
        XCTAssertEqual(FlightDynamicsClient.RawFlight.parseZone("GMT-05:30")?.secondsFromGMT(), -(5 * 3600 + 30 * 60))
        XCTAssertNil(FlightDynamicsClient.RawFlight.parseZone("费解"))
    }

    // MARK: 航司名

    func testAirlineNames() {
        XCTAssertEqual(AirlineNames.name(forFlightNo: "3U8633"), "四川航空")
        XCTAssertEqual(AirlineNames.name(forFlightNo: "ca4597"), "中国国航")
        XCTAssertNil(AirlineNames.name(forFlightNo: "XX123"))
        XCTAssertNil(AirlineNames.name(forFlightNo: "C"))
    }
}
