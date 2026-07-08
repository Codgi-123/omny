import XCTest
@testable import OmnyCore

// MARK: - 测试替身

/// 按 (method, path) 路由返回预置响应，并记录所有请求
actor MockTransport: HTTPTransport {
    private(set) var requests: [URLRequest] = []
    private let handler: @Sendable (URLRequest) -> (Data, Int)

    init(handler: @escaping @Sendable (URLRequest) -> (Data, Int)) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (data, status) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: nil)!
        return (data, response)
    }

    func recordedRequests() -> [URLRequest] { requests }
}

actor InMemoryTodoStore: TodoSyncStore {
    private(set) var todos: [UUID: SyncableTodo] = [:]

    init(_ initial: [SyncableTodo]) {
        for todo in initial { todos[todo.localID] = todo }
    }

    func localTodos() async throws -> [SyncableTodo] {
        Array(todos.values).sorted { $0.localID.uuidString < $1.localID.uuidString }
    }

    func upsertFromRemote(_ task: DidaTask) async throws {
        if let existing = todos.values.first(where: { $0.didaTaskID == task.id }) {
            var updated = existing
            updated.title = task.title
            updated.note = task.content
            updated.due = task.dueDate.flatMap(DidaDate.date(from:))
            updated.isCompleted = task.isCompleted
            todos[existing.localID] = updated
        } else {
            let new = SyncableTodo(localID: UUID(), didaTaskID: task.id, title: task.title,
                                   note: task.content,
                                   due: task.dueDate.flatMap(DidaDate.date(from:)),
                                   isCompleted: task.isCompleted, needsPush: false)
            todos[new.localID] = new
        }
    }

    func deleteFromRemote(didaTaskID: String) async throws {
        guard let existing = todos.values.first(where: { $0.didaTaskID == didaTaskID }) else { return }
        todos[existing.localID] = nil
    }

    func markPushed(localID: UUID, didaTaskID: String) async throws {
        guard var todo = todos[localID] else { return }
        todo.didaTaskID = didaTaskID
        todo.needsPush = false
        todos[localID] = todo
    }

    func purge(localID: UUID) async throws {
        todos[localID] = nil
    }

    func snapshot() -> [SyncableTodo] { Array(todos.values) }
}

// MARK: - OAuth

final class DidaOAuthTests: XCTestCase {
    func testAuthorizeURL() throws {
        let url = DidaOAuth.authorizeURL(clientID: "cid123", redirectURI: "http://localhost/omny/oauth",
                                         state: "xyz")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "dida365.com")
        XCTAssertEqual(components.path, "/oauth/authorize")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(query["client_id"], "cid123")
        XCTAssertEqual(query["scope"], "tasks:read tasks:write")
        XCTAssertEqual(query["redirect_uri"], "http://localhost/omny/oauth")
        XCTAssertEqual(query["response_type"], "code")
        XCTAssertEqual(query["state"], "xyz")
    }

    func testTokenRequestUsesBasicAuth() throws {
        let request = DidaOAuth.tokenRequest(clientID: "cid", clientSecret: "secret",
                                             code: "authcode", redirectURI: "http://localhost/omny/oauth")
        XCTAssertEqual(request.httpMethod, "POST")
        let expected = "Basic " + Data("cid:secret".utf8).base64EncodedString()
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), expected)
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("grant_type=authorization_code"))
        XCTAssertTrue(body.contains("code=authcode"))
    }
}

// MARK: - 同步引擎

final class DidaSyncEngineTests: XCTestCase {

    /// 一次覆盖五种情形的综合同步场景
    func testFullSyncScenario() async throws {
        let newTodoID = UUID()
        let dirtyDoneID = UUID()
        let deletedID = UUID()
        let cleanID = UUID()
        let completedRemotelyID = UUID()

        let store = InMemoryTodoStore([
            // 1. 本地新建，未推送过 → 应 create
            SyncableTodo(localID: newTodoID, title: "发周报", needsPush: true),
            // 2. 已同步，本地勾选完成 → 应 update + complete
            SyncableTodo(localID: dirtyDoneID, didaTaskID: "dida-2", title: "买菜",
                         isCompleted: true, needsPush: true),
            // 3. 已同步，本地删除 → 应 DELETE + purge
            SyncableTodo(localID: deletedID, didaTaskID: "dida-3", title: "旧任务",
                         needsPush: false, isDeletedLocally: true),
            // 4. 已同步无变化，远端改了标题 → 应被远端覆盖
            SyncableTodo(localID: cleanID, didaTaskID: "dida-4", title: "旧标题", needsPush: false),
            // 5. 已同步无变化，远端未完成列表里消失 → 应标记为已完成
            SyncableTodo(localID: completedRemotelyID, didaTaskID: "dida-5", title: "在滴答里完成的",
                         needsPush: false),
        ])

        let transport = MockTransport { request in
            let path = request.url!.path
            let method = request.httpMethod!
            switch (method, path) {
            case ("POST", "/open/v1/task"):
                return (Data(#"{"id":"dida-new-1","projectId":"p1","title":"发周报"}"#.utf8), 200)
            case ("POST", "/open/v1/task/dida-2"):
                return (Data(#"{"id":"dida-2","projectId":"p1","title":"买菜"}"#.utf8), 200)
            case ("POST", "/open/v1/project/p1/task/dida-2/complete"):
                return (Data(), 200)
            case ("DELETE", "/open/v1/project/p1/task/dida-3"):
                return (Data(), 200)
            case ("GET", "/open/v1/project/p1/task/dida-2"):
                // 本地刚勾选完成并推送 → 未完成列表里没有它，逐个核实拿到已完成态
                return (Data(#"{"id":"dida-2","projectId":"p1","title":"买菜","status":2}"#.utf8), 200)
            case ("GET", "/open/v1/project/p1/task/dida-5"):
                // 在滴答侧被完成 → 核实拿到已完成态
                return (Data(#"{"id":"dida-5","projectId":"p1","title":"在滴答里完成的","status":2}"#.utf8), 200)
            case ("GET", "/open/v1/project/p1/data"):
                // 远端未完成列表：dida-4 改了标题；dida-6 是滴答侧新建的；dida-5 消失（已在滴答完成）
                let json = #"""
                {"project":{"id":"p1","name":"Omny"},
                 "tasks":[
                   {"id":"dida-4","projectId":"p1","title":"新标题","status":0},
                   {"id":"dida-6","projectId":"p1","title":"滴答里新建的任务","dueDate":"2026-07-10T10:00:00+0000","status":0},
                   {"id":"dida-new-1","projectId":"p1","title":"发周报","status":0}
                 ]}
                """#
                return (Data(json.utf8), 200)
            default:
                XCTFail("意外请求: \(method) \(path)")
                return (Data(), 500)
            }
        }

        let engine = DidaSyncEngine(
            client: DidaClient(accessToken: "token", transport: transport),
            store: store, projectID: "p1")
        try await engine.sync()

        let result = await store.snapshot()
        func find(_ id: UUID) -> SyncableTodo? { result.first { $0.localID == id } }

        // 1. 新建已推送并拿到滴答 ID
        XCTAssertEqual(find(newTodoID)?.didaTaskID, "dida-new-1")
        XCTAssertEqual(find(newTodoID)?.needsPush, false)
        // 2. 完成状态已推送
        XCTAssertEqual(find(dirtyDoneID)?.needsPush, false)
        // 3. 本地删除的已彻底清理
        XCTAssertNil(find(deletedID))
        // 4. 远端标题覆盖本地
        XCTAssertEqual(find(cleanID)?.title, "新标题")
        // 5. 远端消失 → 本地标记完成（而不是删除）
        XCTAssertEqual(find(completedRemotelyID)?.isCompleted, true)
        // 6. 滴答侧新建的任务落地到本地，带截止时间
        let pulled = result.first { $0.didaTaskID == "dida-6" }
        XCTAssertEqual(pulled?.title, "滴答里新建的任务")
        XCTAssertNotNil(pulled?.due)
        XCTAssertEqual(pulled?.needsPush, false)

        // 请求都带上了 Bearer token
        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer token"
        })
    }

    func testDeleteAlreadyGoneRemotelyStillPurges() async throws {
        let deletedID = UUID()
        let store = InMemoryTodoStore([
            SyncableTodo(localID: deletedID, didaTaskID: "dida-9", title: "远端已没了",
                         needsPush: false, isDeletedLocally: true),
        ])
        let transport = MockTransport { request in
            if request.httpMethod == "DELETE" { return (Data(), 404) }
            return (Data(#"{"project":{"id":"p1","name":"A"},"tasks":[]}"#.utf8), 200)
        }
        let engine = DidaSyncEngine(
            client: DidaClient(accessToken: "t", transport: transport),
            store: store, projectID: "p1")
        try await engine.sync()
        let result = await store.snapshot()
        XCTAssertTrue(result.isEmpty, "远端 404 也应完成本地清理")
    }

    /// 用户在滴答里改了一个"已完成"任务：它不在未完成列表里，靠逐个 GET 核实把改动拉回本地
    func testRemoteEditOfCompletedTaskIsPulled() async throws {
        let localID = UUID()
        let store = InMemoryTodoStore([
            SyncableTodo(localID: localID, didaTaskID: "dida-1", title: "旧标题",
                         isCompleted: true, needsPush: false),
        ])
        let transport = MockTransport { request in
            switch (request.httpMethod!, request.url!.path) {
            case ("GET", "/open/v1/project/p1/data"):
                // 已完成任务不在未完成列表里
                return (Data(#"{"project":{"id":"p1","name":"Omny"},"tasks":[]}"#.utf8), 200)
            case ("GET", "/open/v1/project/p1/task/dida-1"):
                // 逐个核实：远端把标题改了，仍是已完成
                return (Data(#"{"id":"dida-1","projectId":"p1","title":"滴答里改的新标题","status":2}"#.utf8), 200)
            default:
                XCTFail("意外请求: \(request.httpMethod!) \(request.url!.path)")
                return (Data(), 500)
            }
        }
        let engine = DidaSyncEngine(
            client: DidaClient(accessToken: "t", transport: transport),
            store: store, projectID: "p1")
        try await engine.sync()

        let result = await store.snapshot()
        let todo = result.first { $0.didaTaskID == "dida-1" }
        XCTAssertEqual(todo?.title, "滴答里改的新标题", "已完成任务的远端改动应被拉回")
        XCTAssertEqual(todo?.isCompleted, true)
    }

    /// 已同步任务在滴答侧被删除：单任务 GET 返回 404 → 本地删除（而非误判为已完成）
    func testRemoteDeleteRemovesLocal() async throws {
        let localID = UUID()
        let store = InMemoryTodoStore([
            SyncableTodo(localID: localID, didaTaskID: "dida-1", title: "会被删除的",
                         needsPush: false),
        ])
        let transport = MockTransport { request in
            switch (request.httpMethod!, request.url!.path) {
            case ("GET", "/open/v1/project/p1/data"):
                return (Data(#"{"project":{"id":"p1","name":"Omny"},"tasks":[]}"#.utf8), 200)
            case ("GET", "/open/v1/project/p1/task/dida-1"):
                return (Data(#"{}"#.utf8), 404)
            default:
                XCTFail("意外请求: \(request.httpMethod!) \(request.url!.path)")
                return (Data(), 500)
            }
        }
        let engine = DidaSyncEngine(
            client: DidaClient(accessToken: "t", transport: transport),
            store: store, projectID: "p1")
        try await engine.sync()

        let result = await store.snapshot()
        XCTAssertTrue(result.isEmpty, "远端删除应让本地一并删除")
    }

    func testUnauthorizedSurfacesAsDidaError() async throws {
        let transport = MockTransport { _ in (Data(), 401) }
        let client = DidaClient(accessToken: "expired", transport: transport)
        do {
            _ = try await client.projects()
            XCTFail("应抛出 unauthorized")
        } catch let error as DidaError {
            XCTAssertEqual(error, .unauthorized)
        }
    }

    func testDidaDateRoundTrip() {
        let date = DidaDate.date(from: "2026-07-10T10:00:00+0000")
        XCTAssertNotNil(date)
        XCTAssertEqual(DidaDate.string(from: date!), "2026-07-10T10:00:00+0000")
    }

    func testDidaDateParsesMilliseconds() {
        // 真实 API 返回带毫秒（文档没写），2026-07-08 联调确认
        let date = DidaDate.date(from: "2026-07-10T10:00:00.000+0000")
        XCTAssertNotNil(date)
        XCTAssertEqual(date, DidaDate.date(from: "2026-07-10T10:00:00+0000"))
    }

    func testDecodeRealAPIResponse() throws {
        // 2026-07-08 真实联调抓的响应原文
        let json = #"""
        {"id":"6a4e38eee4b0910b33ba6011","projectId":"6a4e38eee4b05bd031231273",
         "sortOrder":-1099511627776,"title":"Omny 联调测试任务","content":"来自截图OCR的测试",
         "startDate":"2026-07-10T10:00:00.000+0000","dueDate":"2026-07-10T10:00:00.000+0000",
         "timeZone":"Asia/Shanghai","isAllDay":false,"priority":0,"status":0,"tags":[],
         "etag":"c6t6qqyz","etimestamp":1783511278844,"kind":"TEXT",
         "modifiedTime":"2026-07-08T11:47:58.843+0000","createdTime":"2026-07-08T11:47:58.843+0000"}
        """#
        let task = try JSONDecoder().decode(DidaTask.self, from: Data(json.utf8))
        XCTAssertEqual(task.id, "6a4e38eee4b0910b33ba6011")
        XCTAssertEqual(task.etag, "c6t6qqyz")
        XCTAssertNotNil(task.modifiedTime)
        XCTAssertNotNil(task.dueDate.flatMap(DidaDate.date(from:)), "带毫秒的截止时间必须能解析")
        XCTAssertFalse(task.isCompleted)
    }
}
