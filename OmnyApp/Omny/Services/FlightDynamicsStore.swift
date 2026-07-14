import Foundation
import SwiftUI
import OmnyCore

/// 航班动态本地缓存：key「航班号|起飞日期」。
/// 刷新策略（与需求一致）：缓存 10 分钟内视为新鲜——自动刷新（页面出现 / .task）只拉
/// 缺失或过期的航班；用户下拉刷新（force）无视 TTL 全部重拉。持久化到 UserDefaults，
/// 重启后缓存仍在，过期与否由 fetchedAt 判断。
@MainActor
final class FlightDynamicsStore: ObservableObject {
    static let shared = FlightDynamicsStore()

    /// 缓存有效期：10 分钟
    static let ttl: TimeInterval = 10 * 60

    struct Entry: Codable {
        var data: FlightDynamics
        var fetchedAt: Date
    }

    @Published private(set) var entries: [String: Entry] = [:]

    private let defaultsKey = "flightDynamicsCache.v1"
    private var refreshing = false
    private let client = FlightDynamicsClient(
        endpoint: URL(string: Secrets.flightMCPURL)!, apiKey: Secrets.flightMCPKey)

    private init() { load() }

    // MARK: 读

    func dynamics(for item: InboxItem) -> FlightDynamics? {
        guard let query = Self.query(for: item) else { return nil }
        return entries[query.key]?.data
    }

    // MARK: 刷

    /// force=false：只拉缓存缺失或超过 TTL 的航班；force=true：下拉刷新，全部重拉。
    /// 失败静默——卡片自动退回短信解析出的字段。
    func refresh(_ items: [InboxItem], force: Bool) async {
        let now = Date()
        var queries = Set(items.compactMap { Self.query(for: $0) })
        if !force {
            queries = queries.filter { query in
                guard let entry = entries[query.key] else { return true }
                return now.timeIntervalSince(entry.fetchedAt) > Self.ttl
            }
        }
        guard !queries.isEmpty, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let fetched = try await client.fetch(Array(queries))
            let fetchedAt = Date()
            for flight in fetched {
                entries[flight.key] = Entry(data: flight, fetchedAt: fetchedAt)
            }
            prune()
            save()
        } catch {
            // 无网/网关抖动不打扰用户；下拉或下次过期会再试
        }
    }

    /// InboxItem → 查询。只查航班类行程，且起飞时间在「昨天之后」——更早的动态没有展示价值。
    static func query(for item: InboxItem) -> FlightQuery? {
        guard item.kind == .trip, item.tripKindRaw == "flight",
              let number = item.tripNumber, !number.isEmpty,
              let departAt = item.departAt,
              departAt > Date(timeIntervalSinceNow: -86400) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return FlightQuery(no: number, date: formatter.string(from: departAt))
    }

    // MARK: 持久化

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    /// 拉取超过 3 天的条目清掉，缓存不无限增长
    private func prune() {
        let cutoff = Date(timeIntervalSinceNow: -3 * 86400)
        entries = entries.filter { $0.value.fetchedAt > cutoff }
    }
}
