import Foundation
import SwiftData
import OmnyCore

/// 滴答清单：绑定（OAuth）与双向同步。同步引擎在 OmnyCore，这里做 SwiftData 适配。
@MainActor
final class DidaService: ObservableObject {
    static let shared = DidaService()

    @Published var syncing = false
    @Published var lastError: String?

    /// 上次发起同步的时间，用于前台切换时的防抖
    private var lastAttempt: Date?

    private init() {}

    // MARK: 绑定

    var authorizeURL: URL {
        DidaOAuth.authorizeURL(clientID: AppSettings.didaClientID,
                               redirectURI: AppSettings.didaRedirectURI,
                               state: "omny")
    }

    /// WebView 拦截到回跳后调用：code 换 token，找到/创建 Omny 清单
    func completeBinding(code: String) async throws {
        let token = try await DidaOAuth.exchangeCode(
            clientID: AppSettings.didaClientID,
            clientSecret: AppSettings.didaClientSecret,
            code: code,
            redirectURI: AppSettings.didaRedirectURI)

        let settings = AppSettings.shared
        settings.didaAccessToken = token.accessToken

        let client = DidaClient(accessToken: token.accessToken)
        let projects = try await client.projects()
        if let existing = projects.first(where: { $0.name == "Omny" && $0.closed != true }) {
            settings.didaProjectID = existing.id
            settings.didaProjectName = existing.name
        } else {
            let created = try await client.createProject(name: "Omny")
            settings.didaProjectID = created.id
            settings.didaProjectName = created.name
        }
    }

    func unbind() {
        let settings = AppSettings.shared
        settings.didaAccessToken = nil
        settings.didaProjectID = nil
        settings.didaProjectName = nil
        settings.didaLastSync = nil
    }

    // MARK: 同步

    /// 前台回来时调用：距上次发起同步不足 minInterval 则跳过，避免频繁切换反复拉取。
    func syncOnForeground(context: ModelContext, minInterval: TimeInterval = 30) async {
        if let last = lastAttempt, Date().timeIntervalSince(last) < minInterval { return }
        await syncNow(context: context)
    }

    func syncNow(context: ModelContext) async {
        let settings = AppSettings.shared
        guard let token = settings.didaAccessToken, let projectID = settings.didaProjectID,
              !syncing else { return }
        lastAttempt = .now
        syncing = true
        lastError = nil
        defer { syncing = false }

        let engine = DidaSyncEngine(
            client: DidaClient(accessToken: token),
            store: SwiftDataTodoStore(context: context),
            projectID: projectID)
        do {
            try await engine.sync()
            settings.didaLastSync = .now
        } catch DidaError.unauthorized {
            lastError = "授权已过期，请在设置中重新绑定滴答清单"
        } catch is CancellationError {
            // 下拉手势结束/视图刷新导致的任务取消是正常事件，不算失败
        } catch let error as URLError where error.code == .cancelled {
            // 同上：URLSession 层的取消
        } catch {
            lastError = "同步失败：\(error.localizedDescription)"
        }
    }
}

/// TodoSyncStore 的 SwiftData 实现：InboxItem(kind=todo) ↔ SyncableTodo
@MainActor
final class SwiftDataTodoStore: TodoSyncStore {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    private func fetchTodos() throws -> [InboxItem] {
        let kindRaw = ItemKind.todo.rawValue
        return try context.fetch(FetchDescriptor<InboxItem>(
            predicate: #Predicate { $0.kindRaw == kindRaw }))
    }

    func localTodos() async throws -> [SyncableTodo] {
        try fetchTodos()
            // 只有滴答来源的待办参与同步：本地新建/截图/短信来源的待办纯本地，不推送也不受拉取影响。
            // needsReview（截图识别待确认）的也先不参与。
            .filter { $0.isDidaSynced && !$0.needsReview }
            .map { item in
                SyncableTodo(localID: item.id, didaTaskID: item.didaTaskID,
                             title: item.todoTitle ?? item.rawText,
                             note: item.todoNote, due: item.todoDue,
                             isCompleted: item.todoCompleted,
                             priority: item.todoPriority,
                             needsPush: item.needsPush,
                             isDeletedLocally: item.deletedLocally)
            }
    }

    func upsertFromRemote(_ task: DidaTask) async throws {
        let todos = try fetchTodos()
        let due = task.dueDate.flatMap(DidaDate.date(from:))
        if let existing = todos.first(where: { $0.didaTaskID == task.id }) {
            existing.todoTitle = task.title
            existing.todoNote = task.content
            existing.todoDue = due
            existing.todoCompleted = task.isCompleted
            existing.todoPriority = task.priority ?? 0
        } else {
            let item = InboxItem(kind: .todo, source: .dida, rawText: task.title)
            item.todoTitle = task.title
            item.todoNote = task.content
            item.todoDue = due
            item.todoCompleted = task.isCompleted
            item.todoPriority = task.priority ?? 0
            item.didaTaskID = task.id
            item.needsPush = false
            context.insert(item)
        }
        try context.save()
    }

    func deleteFromRemote(didaTaskID: String) async throws {
        guard let item = try fetchTodos().first(where: { $0.didaTaskID == didaTaskID }) else { return }
        context.delete(item)
        try context.save()
    }

    func markPushed(localID: UUID, didaTaskID: String) async throws {
        guard let item = try fetchTodos().first(where: { $0.id == localID }) else { return }
        item.didaTaskID = didaTaskID
        item.needsPush = false
        try context.save()
    }

    func purge(localID: UUID) async throws {
        guard let item = try fetchTodos().first(where: { $0.id == localID }) else { return }
        context.delete(item)
        try context.save()
    }
}
