import SwiftUI
import OmnyCore

/// 通用记账条目清单页（可 push）：复用 ExpenseRow 卡片与 ExpenseDetailView 跳转。
/// 数据统计里点「支出/收入」总额、点环形图某分类，都进这个页面看构成明细（issue #28 三.5/三.6）。
struct ExpenseItemListView: View {
    let title: String
    let items: [InboxItem]

    var body: some View {
        List {
            ForEach(items) { item in
                NavigationLink { ExpenseDetailView(item: item) } label: {
                    ExpenseRow(item: item)
                }
                .cardCell()
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.screen)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if items.isEmpty {
                ContentUnavailableView("暂无记录", systemImage: "tray")
            }
        }
    }
}
