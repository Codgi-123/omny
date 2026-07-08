import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP 传输抽象：真机用 URLSession，测试用 Mock。
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DidaError.invalidResponse
        }
        return (data, http)
    }
}

public enum DidaError: Error, Equatable {
    case invalidResponse
    /// 401：token 失效，需要重新授权
    case unauthorized
    case httpError(status: Int, body: String)
    case missingTaskID
}

// MARK: - OAuth

public enum DidaOAuth {
    public static let authorizeEndpoint = URL(string: "https://dida365.com/oauth/authorize")!
    public static let tokenEndpoint = URL(string: "https://dida365.com/oauth/token")!
    public static let scope = "tasks:read tasks:write"

    public struct TokenResponse: Codable, Sendable {
        public var accessToken: String
        public var tokenType: String?
        public var expiresIn: Int?
        public var refreshToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case tokenType = "token_type"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
        }
    }

    /// 第一步：在 ASWebAuthenticationSession 里打开这个 URL
    public static func authorizeURL(clientID: String, redirectURI: String, state: String) -> URL {
        var components = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
        ]
        return components.url!
    }

    /// 第三步：拿回跳里的 code 换 access token（client 凭据走 Basic Auth）
    public static func tokenRequest(clientID: String, clientSecret: String,
                                    code: String, redirectURI: String) -> URLRequest {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        let basic = Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
        ]
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        return request
    }

    public static func exchangeCode(clientID: String, clientSecret: String, code: String,
                                    redirectURI: String,
                                    transport: any HTTPTransport = URLSessionTransport()) async throws -> TokenResponse {
        let request = tokenRequest(clientID: clientID, clientSecret: clientSecret,
                                   code: code, redirectURI: redirectURI)
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else {
            throw DidaError.httpError(status: response.statusCode,
                                      body: String(decoding: data, as: UTF8.self))
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }
}

// MARK: - API Client

public struct DidaClient: Sendable {
    public static let baseURL = URL(string: "https://api.dida365.com/open/v1")!

    public var accessToken: String
    public var transport: any HTTPTransport

    public init(accessToken: String, transport: any HTTPTransport = URLSessionTransport()) {
        self.accessToken = accessToken
        self.transport = transport
    }

    // MARK: 清单

    public func projects() async throws -> [DidaProject] {
        try await request("GET", path: "project")
    }

    /// 拉取一个清单的全部未完成任务 —— 拉取方向的同步就靠它（Open API 无增量接口）
    public func projectData(projectID: String) async throws -> DidaProjectData {
        try await request("GET", path: "project/\(projectID)/data")
    }

    public func createProject(name: String) async throws -> DidaProject {
        struct Body: Encodable { let name: String }
        return try await request("POST", path: "project", body: Body(name: name))
    }

    // MARK: 任务

    public func createTask(_ task: DidaTask) async throws -> DidaTask {
        try await request("POST", path: "task", body: task)
    }

    public func updateTask(_ task: DidaTask) async throws -> DidaTask {
        guard let id = task.id else { throw DidaError.missingTaskID }
        return try await request("POST", path: "task/\(id)", body: task)
    }

    public func completeTask(projectID: String, taskID: String) async throws {
        try await requestVoid("POST", path: "project/\(projectID)/task/\(taskID)/complete")
    }

    public func deleteTask(projectID: String, taskID: String) async throws {
        try await requestVoid("DELETE", path: "project/\(projectID)/task/\(taskID)")
    }

    // MARK: 底层

    func makeRequest(_ method: String, path: String, bodyData: Data?) -> URLRequest {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let bodyData {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = bodyData
        }
        return request
    }

    func send(_ method: String, path: String, body: (some Encodable)?) async throws -> Data {
        let bodyData = try body.map { try JSONEncoder().encode($0) }
        let request = makeRequest(method, path: path, bodyData: bodyData)
        let (data, response) = try await transport.send(request)
        switch response.statusCode {
        case 200, 201, 204: return data
        case 401: throw DidaError.unauthorized
        default:
            throw DidaError.httpError(status: response.statusCode,
                                      body: String(decoding: data, as: UTF8.self))
        }
    }

    func request<T: Decodable>(_ method: String, path: String,
                               body: (some Encodable)? = Optional<DidaTask>.none) async throws -> T {
        let data = try await send(method, path: path, body: body)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func requestVoid(_ method: String, path: String) async throws {
        _ = try await send(method, path: path, body: Optional<DidaTask>.none)
    }
}
