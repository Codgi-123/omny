import SwiftUI
import OmnyCore

/// 设置页一级页面：按使用频率分层（issue #10 问题3，HIG Settings：用户很少进设置、
/// 设置项要少、按调整频率分主次）。
/// 结构：服务（状态行，点入二级页）→ 常用 → 数据 → 高级设置 → 帮助 → 关于。
/// 二级页拆分在 Views/Settings/ 目录：LLMSettingsView / DidaSettingsView /
/// AdvancedSettingsView / ShortcutsGuideView / DeveloperToolsView。
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            // MARK: 服务（状态行模式：不点进去也能看到当前状态）
            Section {
                NavigationLink {
                    LLMSettingsView()
                } label: {
                    statusRow(title: "LLM 解析引擎", status: llmStatus)
                }
                NavigationLink {
                    DidaSettingsView()
                } label: {
                    statusRow(title: "滴答清单", status: didaStatus)
                }
            } header: {
                Text("服务")
            }

            // MARK: 常用（高频调整项直接放一级页）
            Section {
                Toggle("行程自动写入日历", isOn: $settings.autoAddToCalendar)
                NavigationLink {
                    TagManageView()
                } label: {
                    LabeledContent("收藏标签", value: "\(settings.bookmarkTags.count) 个")
                }
                NavigationLink {
                    ExpenseCategoryManageView()
                } label: {
                    LabeledContent("消费分类", value: "\(settings.expenseCategoryPool.count) 个大类")
                }
            } header: {
                Text("常用")
            } footer: {
                Text("收藏打标与记账分类都由 LLM 从对应池子里挑选；未配置 LLM 时照常入库，标签/分类手动补。")
            }

            // MARK: 数据
            Section("数据") {
                NavigationLink("需处理内容") { ReviewView() }
                NavigationLink("回收站") { TrashView() }
            }

            // MARK: 高级设置（低频参数 + 危险操作，整体收纳进二级页）
            Section {
                NavigationLink("高级设置") { AdvancedSettingsView() }
            } footer: {
                Text("解析阈值、去重时间窗、同步间隔、缓存有效期等低频参数，以及清空数据的危险操作。")
            }

            // MARK: 帮助
            Section("帮助") {
                NavigationLink("快捷指令安装与教程") { ShortcutsGuideView() }
            }

            // MARK: 关于
            Section("关于") {
                LabeledContent("版本", value: Self.appVersion)
                NavigationLink("开发者工具") { DeveloperToolsView() }
            }
        }
        .navigationTitle("设置")
        .toolbar(.hidden, for: .tabBar)   // 进设置隐藏底部 tab 栏
    }

    // MARK: 状态行

    /// 服务行：标题 + 当前状态副标题（HIG 状态行模式）
    private func statusRow(title: String, status: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(status)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// LLM 状态：从 llmConfig 是否可用如实推断（连通性测试结果是临时态，不持久化不冒充）。
    private var llmStatus: String {
        settings.llmConfig != nil ? "\(settings.llmModel) · 已配置" : "未配置"
    }

    /// 滴答状态：已绑定时带上次同步的相对时间。
    private var didaStatus: String {
        guard settings.didaBound else { return "未绑定" }
        guard let last = settings.didaLastSync else { return "已绑定 · 尚未同步" }
        let relative = last.formatted(.relative(presentation: .named))
        return "已绑定 · 上次同步\(relative)"
    }

    /// 版本号从 Bundle 读，不再硬编码（MARKETING_VERSION + 构建号）。
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(version) (\($0))" } ?? version
    }
}
