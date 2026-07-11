import Foundation

/// 参与同步的本地待办快照（与 SwiftData 实体解耦，App 层做转换）。
public struct SyncableTodo: Equatable, Sendable {
    public var localID: UUID
    /// 已同步过的待办持有滴答侧任务 ID；nil 表示还没推送过
    public var didaTaskID: String?
    public var title: String
    public var note: String?
    public var due: Date?
    public var isCompleted: Bool
    /// 优先级，取值对齐滴答（0 无 / 1 低 / 3 中 / 5 高）
    public var priority: Int
    /// 本地有滴答侧还不知道的修改
    public var needsPush: Bool
    /// 本地已删除，等待推送删除后彻底清理
    public var isDeletedLocally: Bool

    public init(localID: UUID, didaTaskID: String? = nil, title: String,
                note: String? = nil, due: Date? = nil, isCompleted: Bool = false,
                priority: Int = 0, needsPush: Bool = true, isDeletedLocally: Bool = false) {
        self.localID = localID
        self.didaTaskID = didaTaskID
        self.title = title
        self.note = note
        self.due = due
        self.isCompleted = isCompleted
        self.priority = priority
        self.needsPush = needsPush
        self.isDeletedLocally = isDeletedLocally
    }

    func asDidaTask(projectID: String) -> DidaTask {
        DidaTask(id: didaTaskID, projectId: projectID, title: title, content: note,
                 dueDate: due.map(DidaDate.string(from:)),
                 priority: priority,
                 status: isCompleted ? 2 : 0)
    }
}

/// 本地存储需要为同步提供的原语。App 层用 SwiftData 实现，测试用内存实现。
public protocol TodoSyncStore: Sendable {
    func localTodos() async throws -> [SyncableTodo]
    /// 远端任务落地：按 didaTaskID upsert（标题/截止时间/完成状态都以远端为准）
    func upsertFromRemote(_ task: DidaTask) async throws
    /// 远端确认已删除（单任务 GET 返回 404）→ 本地一并删除
    func deleteFromRemote(didaTaskID: String) async throws
    /// 推送成功后清脏标记、记录滴答任务 ID
    func markPushed(localID: UUID, didaTaskID: String) async throws
    /// 本地删除已推送到远端，彻底移除
    func purge(localID: UUID) async throws
}

/// 双向同步引擎：先推后拉。
///
/// 冲突策略（Open API 的任务没有服务器修改时间，做不了真正的时间戳比较）：
/// 本地有脏标记的字段修改以本地为准（推送覆盖远端），其余以远端为准。
/// 拉取时对"从未完成列表消失"的已同步任务逐个 GET 核实：能取到就以远端为准
/// （含已完成任务的内容修改），404 才判定为删除 —— 由此能区分滴答侧的完成与删除。
public struct DidaSyncEngine: Sendable {
    public var client: DidaClient
    public var store: any TodoSyncStore
    /// 绑定同步的滴答清单 ID（设置页里选定）
    public var projectID: String

    public init(client: DidaClient, store: any TodoSyncStore, projectID: String) {
        self.client = client
        self.store = store
        self.projectID = projectID
    }

    public func sync() async throws {
        try await push()
        try await pull()
    }

    // MARK: 推送（本地 → 滴答）

    func push() async throws {
        for todo in try await store.localTodos() {
            if todo.isDeletedLocally {
                if let didaID = todo.didaTaskID {
                    do {
                        try await client.deleteTask(projectID: projectID, taskID: didaID)
                    } catch DidaError.httpError(404, _) {
                        // 远端已不存在，视为删除成功
                    }
                }
                try await store.purge(localID: todo.localID)
                continue
            }
            guard todo.needsPush else { continue }

            if let didaID = todo.didaTaskID {
                _ = try await client.updateTask(todo.asDidaTask(projectID: projectID))
                if todo.isCompleted {
                    try await client.completeTask(projectID: projectID, taskID: didaID)
                }
                try await store.markPushed(localID: todo.localID, didaTaskID: didaID)
            } else {
                let created = try await client.createTask(todo.asDidaTask(projectID: projectID))
                guard let newID = created.id else { throw DidaError.missingTaskID }
                if todo.isCompleted {
                    try await client.completeTask(projectID: projectID, taskID: newID)
                }
                try await store.markPushed(localID: todo.localID, didaTaskID: newID)
            }
        }
    }

    // MARK: 拉取（滴答 → 本地）

    func pull() async throws {
        let remoteOpen = try await client.projectData(projectID: projectID).tasks ?? []
        let remoteOpenIDs = Set(remoteOpen.compactMap(\.id))

        // push 之后重新取本地状态
        let locals = try await store.localTodos()
        let dirtyDidaIDs = Set(locals.filter(\.needsPush).compactMap(\.didaTaskID))

        // 1. 未完成列表里的任务：落地（本地仍有未推送修改的跳过，本地为准）
        for task in remoteOpen {
            guard let id = task.id else { continue }
            guard !dirtyDidaIDs.contains(id) else { continue }
            try await store.upsertFromRemote(task)
        }

        // 2. 已同步、但不在未完成列表里的任务：核实真实状态。
        //    能取到 → 以远端为准落地（涵盖"用户在滴答改了已完成任务"这种未完成列表拉不到的情况）；
        //    404 → 远端已删除，本地一并删除。
        //    取舍：Open API 无"已完成任务列表"接口，只能逐个 GET。这些 GET 彼此独立，
        //    并发发起（网络并发、写库串行），避免任务多时 N 次串行往返拖慢同步。
        //    本地仍有未推送修改的（needsPush）跳过，避免覆盖本地待推送的改动。
        let toVerify = locals.filter { todo in
            guard let didaID = todo.didaTaskID,
                  !todo.needsPush, !todo.isDeletedLocally,
                  !remoteOpenIDs.contains(didaID)
            else { return false }
            return true
        }.compactMap(\.didaTaskID)

        let client = self.client
        let projectID = self.projectID
        // (didaTaskID, 远端任务)；任务为 nil 表示远端已删除（404）
        let verified = try await withThrowingTaskGroup(of: (String, DidaTask?).self) { group in
            for didaID in toVerify {
                group.addTask {
                    do {
                        return (didaID, try await client.getTask(projectID: projectID, taskID: didaID))
                    } catch DidaError.httpError(404, _) {
                        return (didaID, nil)
                    }
                }
            }
            var acc: [(String, DidaTask?)] = []
            for try await outcome in group { acc.append(outcome) }
            return acc
        }

        for (didaID, task) in verified {
            if let task {
                try await store.upsertFromRemote(task)
            } else {
                try await store.deleteFromRemote(didaTaskID: didaID)
            }
        }
    }
}
