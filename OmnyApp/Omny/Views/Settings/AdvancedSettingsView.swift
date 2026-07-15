import SwiftUI
import SwiftData
import OmnyCore

/// 高级设置：低频参数按域分 Section（解析 / LLM 请求 / 同步 / 航班 / 数据），
/// 每个 footer 写明默认值与影响；页面底部是独立的红色「危险操作」组。
/// 所有参数的默认值 = 原硬编码值，语义不变（issue #10 问题3 只做可配置化）。
struct AdvancedSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.modelContext) private var context
    @State private var showClearItemsConfirm = false
    @State private var showResetConfirm = false
    @State private var maintenanceResult: String?

    var body: some View {
        Form {
            // MARK: 解析
            Section {
                Stepper(value: $settings.lowConfidenceThreshold, in: 0.5...0.95, step: 0.05) {
                    LabeledContent("低置信度阈值",
                                   value: String(format: "%.2f", settings.lowConfidenceThreshold))
                }
                Toggle("截图待办直接入库", isOn: $settings.screenshotTodoDirectIngest)
                Stepper(value: $settings.expenseDedupWindowMinutes, in: 0...60, step: 5) {
                    LabeledContent("记账去重时间窗",
                                   value: "±\(settings.expenseDedupWindowMinutes) 分钟")
                }
            } header: {
                Text("解析")
            } footer: {
                Text("阈值默认 0.80：解析置信度低于阈值的条目进「需处理」等人工确认，调低漏检多、调高误报多。截图待办默认关闭直接入库（先进「需处理」核对，OCR 噪声大）。去重时间窗默认 ±10 分钟：金额相同且时间在窗内、卡尾号或商户又匹配的记账判为同一笔不重复入库。")
            }

            // MARK: LLM 请求
            Section {
                Stepper(value: $settings.llmMaxTokens, in: 512...8192, step: 256) {
                    LabeledContent("输出 token 上限", value: "\(settings.llmMaxTokens)")
                }
                Stepper(value: $settings.llmTimeoutSeconds, in: 10...300, step: 10) {
                    LabeledContent("请求超时", value: "\(Int(settings.llmTimeoutSeconds)) 秒")
                }
            } header: {
                Text("LLM 请求")
            } footer: {
                Text("token 上限默认 2048，只作用于结构化抽取等大输出任务（打标/分类等小任务各有更小的固定预算）；输出被截断时调大。超时默认 60 秒：网络慢或中转端点响应久时调大，快捷指令场景等太久会被系统掐掉。")
            }

            // MARK: 同步
            Section {
                Stepper(value: $settings.didaForegroundSyncMinInterval, in: 0...300, step: 15) {
                    LabeledContent("滴答前台同步最小间隔",
                                   value: "\(Int(settings.didaForegroundSyncMinInterval)) 秒")
                }
            } header: {
                Text("同步")
            } footer: {
                Text("默认 30 秒：App 回到前台时距上次同步不足该间隔则跳过，避免频繁切换反复全量拉取。0 表示每次回前台都同步。")
            }

            // MARK: 航班
            Section {
                Stepper(value: $settings.flightCacheTTLMinutes, in: 0...120, step: 5) {
                    LabeledContent("航班动态缓存有效期",
                                   value: "\(settings.flightCacheTTLMinutes) 分钟")
                }
            } header: {
                Text("航班")
            } footer: {
                Text("默认 10 分钟：缓存内的航班动态视为新鲜不重复查询，过期或缺失才向航班管家 MCP 拉取；下拉刷新始终全部重拉。调小更实时但查询更频繁。")
            }

            // MARK: 数据
            Section {
                Stepper(value: $settings.trashRetentionDays, in: 1...90, step: 1) {
                    LabeledContent("回收站保留天数", value: "\(settings.trashRetentionDays) 天")
                }
            } header: {
                Text("数据")
            } footer: {
                Text("默认 7 天：删除的条目先进回收站，满保留期后在 App 启动时彻底清除，期间可随时恢复。")
            }

            // MARK: 危险操作（独立红色组，放页面最底部）
            Section {
                Button(role: .destructive) {
                    showClearItemsConfirm = true
                } label: {
                    Label("清空所有条目", systemImage: "trash")
                }
                Button(role: .destructive) {
                    showResetConfirm = true
                } label: {
                    Label("恢复出厂设置", systemImage: "arrow.counterclockwise")
                }
            } header: {
                Text("危险操作")
            } footer: {
                if let result = maintenanceResult {
                    Text(result).foregroundStyle(Theme.green)
                } else {
                    Text("「清空所有条目」删除全部快递/行程/待办/收藏/记账/未分类数据，保留所有配置；「恢复出厂设置」在清空条目的基础上再重置 LLM、滴答绑定、标签、本页参数等所有配置。均不可恢复。")
                }
            }
        }
        .navigationTitle("高级设置")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("清空所有条目？", isPresented: $showClearItemsConfirm, titleVisibility: .visible) {
            Button("清空", role: .destructive) { clearAllItems() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除全部快递、行程、待办、收藏、记账及未处理内容，不可恢复。LLM / 滴答 / 标签等配置保留。")
        }
        .confirmationDialog("恢复出厂设置？", isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button("恢复出厂", role: .destructive) { resetEverything() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除全部条目并重置 LLM、滴答绑定、收藏标签、高级参数等所有配置，不可恢复。")
        }
    }

    /// 删除全部 InboxItem，返回删除条数。保留所有配置。
    @discardableResult
    private func deleteAllItems() -> Int {
        let all = (try? context.fetch(FetchDescriptor<InboxItem>())) ?? []
        for item in all { context.delete(item) }
        try? context.save()
        // 条目全没了，重排会顺带清掉所有已排的本地通知
        NotificationScheduler.requestReschedule(context: context)
        return all.count
    }

    private func clearAllItems() {
        let count = deleteAllItems()
        maintenanceResult = "已清空 \(count) 条数据"
    }

    private func resetEverything() {
        let count = deleteAllItems()
        settings.resetToDefaults()
        maintenanceResult = "已恢复出厂：清空 \(count) 条数据并重置配置"
    }
}
