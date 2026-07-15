import Foundation
import SwiftData
import OmnyCore

// MARK: - InboxItem 统一查询层
// 各视图散落的「按 kind 过滤 + 排除回收站（deletedAt == nil）」手写过滤收敛到这里。
// 新页面一律用这些辅助，不要再在视图里手写 `$0.kind == … && $0.deletedAt == nil`——
// 记账页就曾因漏写 deletedAt 条件，让已软删的条目继续出现在明细/统计里。

extension InboxItem {
    /// 「需处理」的统一数据库谓词：置信度低或待勾选确认，且未被本地删除标记。
    /// RootView 角标 / NavActions 入口红点 / ReviewView 列表三处共用，改动只改这一份。
    /// 注意：这里刻意不排除回收站（deletedAt）——需处理条目在 ReviewCard 里走硬删除、
    /// 不经回收站，与首页 TodayView 用的内存过滤版 pendingReview()（额外排除回收站）
    /// 是既有的语义差异，勿顺手统一。
    static let needsReviewPredicate = #Predicate<InboxItem> {
        $0.needsReview && !$0.deletedLocally
    }
}

extension Sequence where Element == InboxItem {
    /// 活跃条目：未进回收站（deletedAt == nil）；传 kind 时再按类别过滤。
    /// 所有列表视图的基础过滤，快递/行程/收藏/记账页直接用。
    func active(_ kind: ItemKind? = nil) -> [InboxItem] {
        filter { $0.deletedAt == nil && (kind == nil || $0.kind == kind) }
    }

    /// 待办基础集：待办 kind、未进回收站、未被滴答侧标记删除、排除「需处理」低置信项。
    /// 待办页在此基础上再拆 未完成 / 已完成 / 已放弃 三组。
    func activeTodos() -> [InboxItem] {
        active(.todo).filter { !$0.deletedLocally && !$0.needsReview }
    }

    /// 未完成待办：待办基础集里再排除已完成 / 已放弃（首页「今日待办」用）。
    func openTodos() -> [InboxItem] {
        activeTodos().filter { !$0.todoCompleted && !$0.todoAbandoned }
    }

    /// 需处理条目（内存过滤版，首页「需处理」区块用），不限 kind。
    /// 与 needsReviewPredicate 的刻意差异：这里额外排除回收站条目。
    func pendingReview() -> [InboxItem] {
        filter { $0.needsReview && !$0.deletedLocally && $0.deletedAt == nil }
    }

    /// 回收站条目（TrashView 用）：与 active 相反的那一半。
    func trashed() -> [InboxItem] {
        filter { $0.deletedAt != nil }
    }

    /// 待取快递：活跃 + 非低置信 + 状态为「待取」。通知每日汇总与列表角标可共用。
    func awaitingPickupPackages() -> [InboxItem] {
        active(.package).filter { !$0.needsReview && $0.packageStatus == .awaitingPickup }
    }

    /// 未来行程：活跃 + 非低置信 + 出发时间在指定时刻之后（默认现在）。通知排期用。
    func upcomingTrips(after date: Date = .now) -> [InboxItem] {
        active(.trip).filter { !$0.needsReview && ($0.departAt ?? .distantPast) > date }
    }
}
