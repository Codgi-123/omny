import Foundation

// 滴答清单（国内版 Dida365）Open API 数据模型。
// 文档：https://developer.dida365.com/docs#/openapi

public struct DidaTask: Codable, Equatable, Sendable {
    public var id: String?
    public var projectId: String
    public var title: String
    public var content: String?
    public var desc: String?
    public var isAllDay: Bool?
    public var startDate: String?
    public var dueDate: String?
    public var timeZone: String?
    public var priority: Int?
    /// 0 = 未完成，2 = 已完成
    public var status: Int?
    public var completedTime: String?
    /// 以下字段文档未列出、真实 API 会返回（2026-07-08 联调确认），可用于精确冲突判定
    public var etag: String?
    public var modifiedTime: String?

    public init(id: String? = nil, projectId: String, title: String,
                content: String? = nil, desc: String? = nil, isAllDay: Bool? = nil,
                startDate: String? = nil, dueDate: String? = nil, timeZone: String? = nil,
                priority: Int? = nil, status: Int? = nil, completedTime: String? = nil,
                etag: String? = nil, modifiedTime: String? = nil) {
        self.id = id
        self.projectId = projectId
        self.title = title
        self.content = content
        self.desc = desc
        self.isAllDay = isAllDay
        self.startDate = startDate
        self.dueDate = dueDate
        self.timeZone = timeZone
        self.priority = priority
        self.status = status
        self.completedTime = completedTime
        self.etag = etag
        self.modifiedTime = modifiedTime
    }

    public var isCompleted: Bool { status == 2 }
}

public struct DidaProject: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var color: String?
    public var closed: Bool?
    public var kind: String?
}

/// GET /open/v1/project/{id}/data 的响应：清单 + 其未完成任务
public struct DidaProjectData: Codable, Equatable, Sendable {
    public var project: DidaProject
    public var tasks: [DidaTask]?
}

/// 滴答的时间格式。文档写 "2019-11-13T03:00:00+0000"，
/// 但真实 API 响应带毫秒："2026-07-10T10:00:00.000+0000"（2026-07-08 联调确认），两种都要能解析。
public enum DidaDate {
    static func makeFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = format
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }

    public static func string(from date: Date) -> String {
        makeFormatter("yyyy-MM-dd'T'HH:mm:ssZ").string(from: date)
    }

    public static func date(from string: String) -> Date? {
        makeFormatter("yyyy-MM-dd'T'HH:mm:ss.SSSZ").date(from: string)
            ?? makeFormatter("yyyy-MM-dd'T'HH:mm:ssZ").date(from: string)
    }
}
