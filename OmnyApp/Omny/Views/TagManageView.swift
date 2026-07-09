import SwiftUI

/// 收藏标签管理：预置一批，支持增删改与排序。
/// 这里只维护「候选池」；改名/删除不回写存量收藏上的旧标签（旧标签仍显示在筛选栏，
/// 可在条目的「编辑标签」里逐条调整）。
struct TagManageView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var newTag = ""

    var body: some View {
        List {
            Section {
                ForEach(settings.bookmarkTags.indices, id: \.self) { index in
                    TextField("标签", text: Binding(
                        get: {
                            index < settings.bookmarkTags.count ? settings.bookmarkTags[index] : ""
                        },
                        set: { value in
                            guard index < settings.bookmarkTags.count else { return }
                            settings.bookmarkTags[index] = value
                        }))
                }
                .onDelete { settings.bookmarkTags.remove(atOffsets: $0) }
                .onMove { settings.bookmarkTags.move(fromOffsets: $0, toOffset: $1) }

                HStack {
                    TextField("新标签…", text: $newTag)
                        .onSubmit(addTag)
                    Button(action: addTag) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(Theme.accent)
                    }
                    .disabled(trimmedNewTag.isEmpty)
                }
            } footer: {
                Text("左滑删除，长按拖动排序。LLM 自动打标只会从这批标签里选。")
            }

            Section {
                Button("恢复默认标签") {
                    settings.bookmarkTags = AppSettings.defaultBookmarkTags
                }
            }
        }
        .navigationTitle("收藏标签")
        .toolbar { EditButton() }
    }

    private var trimmedNewTag: String {
        newTag.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addTag() {
        let tag = trimmedNewTag
        guard !tag.isEmpty, !settings.bookmarkTags.contains(tag) else { return }
        settings.bookmarkTags.append(tag)
        newTag = ""
    }
}
