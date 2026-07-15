import SwiftUI

/// 快捷指令安装与教程：三条流程的导入按钮 + 图文引导收纳成一页
/// （从旧一级设置页的三个 Section 迁入，issue #10 问题3 设置页分层）。
struct ShortcutsGuideView: View {
    /// 「解析文本」完整流程的 iCloud 分享链接。
    /// 在快捷指令 App 里打开该流程 → 分享 → 拷贝 iCloud 链接，替换下面这行即可。
    static let shortcutImportURL = URL(string: "https://www.icloud.com/shortcuts/086d19c831394dfcac381c6e87be9d69")!

    /// 「截图记忆 / 屏幕识别」流程的 iCloud 分享链接。
    static let screenshotShortcutImportURL = URL(string: "https://www.icloud.com/shortcuts/bb110a85ef5b44489ab20bf808265084")!

    /// 「确认记账」流程的 iCloud 分享链接（屏幕识别 → 确认记账 已绑定好，轻点三下即可）。
    static let confirmExpenseShortcutImportURL = URL(string: "https://www.icloud.com/shortcuts/8c97240b92d4472180c140db8816f301")!

    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section {
                Button {
                    openURL(Self.shortcutImportURL)
                } label: {
                    Label("导入「解析文本」快捷指令", systemImage: "square.and.arrow.down")
                }
            } header: {
                Text("解析文本")
            } footer: {
                Text("""
                第 1 步：点上方按钮，在弹出的页面点「添加快捷指令」，整套流程即导入你的快捷指令库。
                第 2 步：打开快捷指令 App →「自动化」→ 新建 →「信息」→ 收到信息时「立即运行」→ 运行刚导入的「解析文本」，输入选「信息内容」。
                之后每条短信自动解析入库，无需手动操作。
                """)
            }

            Section {
                Button {
                    openURL(Self.screenshotShortcutImportURL)
                } label: {
                    Label("导入「屏幕识别」快捷指令", systemImage: "square.and.arrow.down")
                }
            } header: {
                Text("屏幕识别")
            } footer: {
                Text("""
                第 1 步：点上方按钮，在弹出的页面点「添加快捷指令」。流程内已包含「截屏 → 识别图像文本 → 屏幕识别」，OCR 在快捷指令侧完成。
                第 2 步：手动触发运行——推荐设为「轻点背面两下」（设置 → 辅助功能 → 触控 → 轻点背面）或加进控制中心。iOS 没有「截屏即运行」的自动化触发器，需手动唤起。
                运行后自动截屏、识别文字并归类（快递 / 行程 / 待办 / 收藏），其中待办进「需处理内容」等你确认，其余直接入对应分类。
                """)
            }

            Section {
                Button {
                    openURL(Self.confirmExpenseShortcutImportURL)
                } label: {
                    Label("导入「确认记账」快捷指令", systemImage: "square.and.arrow.down")
                }
            } header: {
                Text("确认记账")
            } footer: {
                Text("""
                第 1 步：点上方按钮，在弹出的页面点「添加快捷指令」。流程内已把「屏幕识别 → 确认记账」直接绑定好，无需手动连线。
                第 2 步：手动触发运行——推荐设为「轻点背面三下」（设置 → 辅助功能 → 触控 → 轻点背面）或加进控制中心。
                运行后截屏识别出的记账会逐笔弹出可编辑表单（收支 / 金额 / 分类 / 时间 / 商户），核对后确认入库；快递 / 行程 / 待办等非记账内容自动入库。适合对自动记账结果做人工核对。
                """)
            }
        }
        .navigationTitle("快捷指令")
        .navigationBarTitleDisplayMode(.inline)
    }
}
