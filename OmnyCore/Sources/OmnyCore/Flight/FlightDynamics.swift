import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - 查询与结果模型

/// 一次航班动态查询：航班号 + 起飞当地日期（yyyy-MM-dd）
public struct FlightQuery: Hashable, Sendable {
    public var no: String
    public var date: String

    public init(no: String, date: String) {
        self.no = no.uppercased()
        self.date = date
    }

    /// 缓存键，与 FlightDynamics.key 同构
    public var key: String { "\(no)|\(date)" }
}

/// 航班动态（来自航班管家 MCP dynamic_flight_batch）。
/// 字段随接口返回可空；时间已按接口给的时区（depZone/arrZone）解析成绝对时间。
public struct FlightDynamics: Codable, Equatable, Sendable {
    public var flightNo: String
    /// 起飞当地日期 yyyy-MM-dd
    public var date: String
    /// 出发/到达机场三字码，如 CTU / PVG
    public var depCode: String?
    public var arrCode: String?
    /// 航站楼，如 T1 / T2
    public var depTerminal: String?
    public var arrTerminal: String?
    /// 登机口（值机开放前常为空）
    public var gate: String?
    /// 行李转盘号
    public var luggage: String?
    /// 值机柜台，如 "R,S,T,U"
    public var checkInCounter: String?
    /// 航班状态原文：计划 / 起飞 / 到达 / 延误 / 取消 …
    public var state: String?
    public var depPlanTime: Date?
    public var arrPlanTime: Date?
    /// 预计（caclTime）：延误时与计划时间不同
    public var depEstimateTime: Date?
    public var arrEstimateTime: Date?

    public var key: String { "\(flightNo.uppercased())|\(date)" }

    public init(flightNo: String, date: String,
                depCode: String? = nil, arrCode: String? = nil,
                depTerminal: String? = nil, arrTerminal: String? = nil,
                gate: String? = nil, luggage: String? = nil, checkInCounter: String? = nil,
                state: String? = nil,
                depPlanTime: Date? = nil, arrPlanTime: Date? = nil,
                depEstimateTime: Date? = nil, arrEstimateTime: Date? = nil) {
        self.flightNo = flightNo
        self.date = date
        self.depCode = depCode
        self.arrCode = arrCode
        self.depTerminal = depTerminal
        self.arrTerminal = arrTerminal
        self.gate = gate
        self.luggage = luggage
        self.checkInCounter = checkInCounter
        self.state = state
        self.depPlanTime = depPlanTime
        self.arrPlanTime = arrPlanTime
        self.depEstimateTime = depEstimateTime
        self.arrEstimateTime = arrEstimateTime
    }
}

public enum FlightDynamicsError: Error, Equatable {
    case httpError(status: Int)
    case invalidResponse
    case mcpError(String)
}

// MARK: - MCP 客户端

/// 航班动态查询客户端：对航班管家 MCP 网关（Streamable HTTP）做最小实现——
/// initialize 握手 → initialized 通知 → tools/call dynamic_flight_batch。
/// 每次 fetch 独立握手（无状态），批量自动按 20 条切分（网关单次上限）。
public struct FlightDynamicsClient: Sendable {
    public var endpoint: URL
    public var apiKey: String
    var transport: any HTTPTransport

    static let batchSize = 20

    public init(endpoint: URL, apiKey: String,
                transport: any HTTPTransport = URLSessionTransport()) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.transport = transport
    }

    public func fetch(_ queries: [FlightQuery]) async throws -> [FlightDynamics] {
        guard !queries.isEmpty else { return [] }

        // 1. initialize 握手，session id 在响应头里
        let (initData, initResp) = try await transport.send(makeRequest([
            "jsonrpc": "2.0", "id": UUID().uuidString, "method": "initialize",
            "params": [
                "protocolVersion": "2025-06-18",
                "capabilities": [String: String](),
                "clientInfo": ["name": "omny", "version": "1.0"],
            ],
        ], session: nil))
        guard (200..<300).contains(initResp.statusCode) else {
            throw FlightDynamicsError.httpError(status: initResp.statusCode)
        }
        _ = try Self.envelope(from: initData)   // error 帧在这里抛出
        let session = Self.sessionID(from: initResp)

        // 2. initialized 通知（无 id；部分网关缺它会拒绝后续调用）
        _ = try? await transport.send(makeRequest(
            ["jsonrpc": "2.0", "method": "notifications/initialized"], session: session))

        // 3. 分批 tools/call
        var results: [FlightDynamics] = []
        var rest = queries[...]
        while !rest.isEmpty {
            let chunk = rest.prefix(Self.batchSize)
            rest = rest.dropFirst(Self.batchSize)
            let (data, resp) = try await transport.send(makeRequest([
                "jsonrpc": "2.0", "id": UUID().uuidString, "method": "tools/call",
                "params": [
                    "name": "dynamic_flight_batch",
                    "arguments": ["flights": chunk.map { ["no": $0.no, "date": $0.date] }],
                ],
            ], session: session))
            guard (200..<300).contains(resp.statusCode) else {
                throw FlightDynamicsError.httpError(status: resp.statusCode)
            }
            results += try Self.parseFlights(from: data)
        }
        return results
    }

    // MARK: 请求构造

    private func makeRequest(_ body: [String: Any], session: String?) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 网关可能以 SSE 帧返回，两种都声明
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let session {
            request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// 大小写不敏感地取 Mcp-Session-Id 响应头（Linux 的 allHeaderFields 键大小写不定）
    static func sessionID(from response: HTTPURLResponse) -> String? {
        for (key, value) in response.allHeaderFields {
            if String(describing: key).lowercased() == "mcp-session-id" {
                return String(describing: value)
            }
        }
        return nil
    }

    // MARK: 响应解析

    /// 归一 JSON-RPC 信封：正文可能是普通 JSON，也可能是 SSE 帧（取第一条 data:）。
    /// error 帧直接抛 mcpError。
    static func envelope(from data: Data) throws -> [String: Any] {
        var jsonData = data
        let text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("event:") || text.hasPrefix("data:") || text.contains("\ndata:") {
            var payload: String?
            for line in text.split(separator: "\n") where line.hasPrefix("data:") {
                let candidate = line.dropFirst("data:".count)
                    .trimmingCharacters(in: .whitespaces)
                if !candidate.isEmpty && candidate != "[DONE]" { payload = candidate; break }
            }
            guard let payload else { throw FlightDynamicsError.invalidResponse }
            jsonData = Data(payload.utf8)
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any] else {
            throw FlightDynamicsError.invalidResponse
        }
        if let error = obj["error"] {
            throw FlightDynamicsError.mcpError(String(describing: error))
        }
        return obj
    }

    /// tools/call 的真实数据在 result.content[].text 里（JSON 字符串，内容是航班数组）
    static func parseFlights(from data: Data) throws -> [FlightDynamics] {
        let env = try envelope(from: data)
        guard let result = env["result"] as? [String: Any],
              let content = result["content"] as? [[String: Any]] else {
            throw FlightDynamicsError.invalidResponse
        }
        var flights: [FlightDynamics] = []
        for piece in content where piece["type"] as? String == "text" {
            guard let text = piece["text"] as? String,
                  let raws = try? JSONDecoder().decode([RawFlight].self, from: Data(text.utf8))
            else { continue }
            flights += raws.compactMap { $0.dynamics }
        }
        return flights
    }

    /// 接口原始字段（只挑用得上的；未知字段忽略）
    struct RawFlight: Decodable {
        var flightNo: String?
        var localDate: String?
        var depCode: String?
        var arrCode: String?
        var depTerm: String?
        var arrTerm: String?
        var gate: String?
        var luggage: String?
        var state: String?
        var depZone: String?
        var arrZone: String?
        var depPlanTime: String?
        var arrPlanTime: String?
        var depCaclTime: String?
        var arrCaclTime: String?
        var checkIn: CheckIn?

        struct CheckIn: Decodable { var counter: String? }

        var dynamics: FlightDynamics? {
            guard let no = flightNo?.nilIfEmpty, let date = localDate?.nilIfEmpty else { return nil }
            return FlightDynamics(
                flightNo: no, date: date,
                depCode: depCode?.nilIfEmpty, arrCode: arrCode?.nilIfEmpty,
                depTerminal: depTerm?.nilIfEmpty, arrTerminal: arrTerm?.nilIfEmpty,
                gate: gate?.nilIfEmpty, luggage: luggage?.nilIfEmpty,
                checkInCounter: checkIn?.counter?.nilIfEmpty,
                state: state?.nilIfEmpty,
                depPlanTime: Self.parseTime(depPlanTime, zone: depZone),
                arrPlanTime: Self.parseTime(arrPlanTime, zone: arrZone),
                depEstimateTime: Self.parseTime(depCaclTime, zone: depZone),
                arrEstimateTime: Self.parseTime(arrCaclTime, zone: arrZone))
        }

        /// "2026-07-14 16:15:00" + "GMT+08:00" → 绝对时间；缺时区按东八区（国内航班）
        static func parseTime(_ raw: String?, zone: String?) -> Date? {
            guard let raw = raw?.nilIfEmpty else { return nil }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            formatter.timeZone = parseZone(zone) ?? TimeZone(secondsFromGMT: 8 * 3600)
            return formatter.date(from: raw)
        }

        /// "GMT+08:00" / "GMT-05:30" → TimeZone
        static func parseZone(_ raw: String?) -> TimeZone? {
            guard let raw,
                  let match = raw.range(of: #"([+-])(\d{1,2}):?(\d{2})"#,
                                        options: .regularExpression) else { return nil }
            let s = raw[match]
            let sign: Int = s.hasPrefix("-") ? -1 : 1
            let digits = s.dropFirst().split(separator: ":")
            guard let hours = Int(digits.first ?? ""),
                  let minutes = digits.count > 1 ? Int(digits[1]) : 0 else { return nil }
            return TimeZone(secondsFromGMT: sign * (hours * 3600 + minutes * 60))
        }
    }
}

// MARK: - 航司名映射

/// 航班号前缀（IATA 二字码）→ 航司中文名。接口不返回航司名，用静态表离线推导；
/// 表外前缀退回 nil，卡片只显示航班号。
public enum AirlineNames {
    static let table: [String: String] = [
        "CA": "中国国航", "MU": "东方航空", "CZ": "南方航空", "HU": "海南航空",
        "3U": "四川航空", "MF": "厦门航空", "ZH": "深圳航空", "SC": "山东航空",
        "GS": "天津航空", "JD": "首都航空", "HO": "吉祥航空", "9C": "春秋航空",
        "KN": "中国联航", "EU": "成都航空", "G5": "华夏航空", "8L": "祥鹏航空",
        "DZ": "东海航空", "GJ": "长龙航空", "DR": "瑞丽航空", "A6": "红土航空",
        "FM": "上海航空", "KY": "昆明航空", "PN": "西部航空", "UQ": "乌鲁木齐航空",
        "GX": "北部湾航空", "QW": "青岛航空", "TV": "西藏航空", "NX": "澳门航空",
        "CX": "国泰航空", "HX": "香港航空", "UO": "香港快运", "CI": "中华航空",
        "BR": "长荣航空", "OZ": "韩亚航空", "KE": "大韩航空", "NH": "全日空",
        "JL": "日本航空", "SQ": "新加坡航空", "TG": "泰国航空", "EK": "阿联酋航空",
    ]

    /// 按航班号前两位查航司名，如 "3U8633" → "四川航空"
    public static func name(forFlightNo flightNo: String) -> String? {
        guard flightNo.count >= 2 else { return nil }
        return table[String(flightNo.prefix(2)).uppercased()]
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
