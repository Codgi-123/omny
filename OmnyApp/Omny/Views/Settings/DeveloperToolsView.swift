import SwiftUI

/// 开发者工具：调试能力的可见入口（设置 → 关于）。
/// HIG 评审明确否决连点解锁的隐藏手势——自用 App 保持可发现性即可。
struct DeveloperToolsView: View {
    var body: some View {
        Form {
            Section {
                NavigationLink {
                    ExpenseDebugView()
                } label: {
                    Label("解析测试", systemImage: "ladybug")
                }
            } header: {
                Text("调试")
            } footer: {
                Text("粘贴动账短信等文本，走与短信快捷指令完全相同的解析管线入库，验证正则分类与 LLM 抽取效果；也可从这里手动记账。")
            }
        }
        .navigationTitle("开发者工具")
        .navigationBarTitleDisplayMode(.inline)
    }
}
