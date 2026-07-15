import SwiftUI
import PhotosUI
import OmnyCore

/// 收藏详情：全屏通栏排版（fullScreenCover + zoom 转场进入），标题/正文/配图连续滚动，无 Form 分框。
/// 替代原 BookmarkDetailSheet：编辑仍是同页 toolbar 切换态，保存语义与原 Sheet 一致；
/// 配图点击进全屏 ZoomableImageView（独立 photoNS，与列表的 zoom 命名空间无关）。
struct BookmarkDetailView: View {
    @Bindable var item: InboxItem
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openURL) private var openURL

    @State private var editing = false
    @State private var draftText = ""
    @State private var selectedTags: [String] = []
    @State private var pickedItem: PhotosPickerItem?
    @State private var showImageViewer = false
    /// 图片查看器的 zoom 命名空间（与列表 push 的 zoomNS 无关）
    @Namespace private var photoNS
    @FocusState private var textFocused: Bool

    private var url: URL? { item.urlString.flatMap(URL.init(string:)) }
    private var candidateTags: [String] {
        settings.mergedTagCandidates(including: item.tags)
    }

    var body: some View {
        Group {
            if editing { editingLayout } else { viewingLayout }
        }
        .background(Theme.screen)
        // 标题在正文里，导航栏留白；宿主是 fullScreenCover（无返回键），关闭按钮自己补
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if editing {
                    Button("取消") { editing = false }
                    Button("完成") { saveEdits() }
                } else {
                    Button("编辑") { startEditing() }
                }
            }
        }
        // 换图/删图不走草稿、即选即存（与原 Sheet 行为一致，「取消」不回滚图片）
        .onChange(of: pickedItem) { _, newItem in
            Task {
                if let data = try? await newItem?.loadTransferable(type: Data.self) {
                    item.sourceImage = data; try? context.save()
                }
            }
        }
        .fullScreenCover(isPresented: $showImageViewer) {
            if let data = item.sourceImage, let ui = UIImage(data: data) {
                ZoomableImageView(image: Image(uiImage: ui))
                    // zoom 必须打在 cover 内容根视图，sourceID 与正文配图一致
                    .navigationTransition(.zoom(sourceID: "photo", in: photoNS))
            }
        }
    }

    // MARK: - 查看态：通栏连续滚动，无分框

    private var viewingLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(title)
                    .font(.title2.bold())
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)

                metaRow

                if item.rawText.isEmpty {
                    Text("（无文字）")
                        .font(.body)
                        .foregroundStyle(Theme.sub)
                } else {
                    Text(item.rawText)
                        .font(.body)
                        .lineSpacing(6)
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                }

                if let data = item.sourceImage, let ui = UIImage(data: data) {
                    Image(uiImage: ui)
                        .resizable()
                        .scaledToFit()
                        .clipShape(.rect(cornerRadius: 12))
                        .matchedTransitionSource(id: "photo", in: photoNS)
                        .onTapGesture { showImageViewer = true }
                }

                tagSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Space.page)
            .padding(.vertical, 12)
        }
    }

    /// 元信息行：相对时间 + （链接型）域名药丸，点击直接跳转
    private var metaRow: some View {
        HStack(spacing: 10) {
            Text(item.createdAt.formatted(.relative(presentation: .named).locale(Locale(identifier: "zh_CN"))))
                .font(.caption)
                .foregroundStyle(Theme.sub)
            if let url {
                Button { openURL(url) } label: {
                    HStack(spacing: 5) {
                        Image("BookmarkLink")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 13, height: 13)
                        Text(url.host() ?? "打开链接")
                            .lineLimit(1)
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4.5)
                    .background(Theme.accent.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var tagSection: some View {
        Group {
            if item.tags.isEmpty {
                Text("未打标")
                    .font(.caption)
                    .foregroundStyle(Theme.sub.opacity(0.7))
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(item.tags, id: \.self) { TagPill(text: $0) }
                }
            }
        }
    }

    // MARK: - 编辑态：全屏 TextEditor + 图片操作 + 标签多选

    private var editingLayout: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 全屏正文编辑：不外套 ScrollView（TextEditor 自带滚动，套了会双滚动冲突）
            TextEditor(text: $draftText)
                .scrollContentBackground(.hidden)
                .background(Theme.screen)
                .lineSpacing(6)
                .padding(.horizontal, 11)   // 补偿 TextEditor 内置约 5pt，与页面 16pt 对齐
                .focused($textFocused)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 12) {
                imageEditRow
                TagPicker(candidates: candidateTags, selection: $selectedTags)
            }
            .padding(.horizontal, Theme.Space.page)
            .padding(.bottom, 10)
        }
    }

    @ViewBuilder
    private var imageEditRow: some View {
        if let data = item.sourceImage, let ui = UIImage(data: data) {
            HStack(spacing: 14) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 52, height: 52)
                    .clipShape(.rect(cornerRadius: 10))
                PhotosPicker(selection: $pickedItem, matching: .images) {
                    Label("更换图片", systemImage: "photo")
                        .font(.subheadline)
                }
                Button(role: .destructive) {
                    item.sourceImage = nil; try? context.save()
                } label: {
                    Label("移除图片", systemImage: "trash")
                        .font(.subheadline)
                }
            }
        } else {
            PhotosPicker(selection: $pickedItem, matching: .images) {
                Label("添加图片", systemImage: "photo.on.rectangle")
                    .font(.subheadline)
            }
        }
    }

    // MARK: - 标题回退与保存（语义与原 BookmarkDetailSheet 一致）

    private var title: String {
        if let bookmarkTitle = item.bookmarkTitle, !bookmarkTitle.isEmpty { return bookmarkTitle }
        // 没抓到标题的链接退回显示域名
        if let url { return url.host() ?? "链接" }
        // 纯文本收藏用首行当标题
        return item.rawText.components(separatedBy: .newlines).first ?? item.rawText
    }

    private func startEditing() {
        draftText = item.rawText
        selectedTags = item.tags
        editing = true
        textFocused = true
    }

    private func saveEdits() {
        item.rawText = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let info = RuleParser.extractBookmark(item.rawText) {
            item.urlString = info.url.absoluteString
            if (item.bookmarkTitle ?? "").isEmpty { item.bookmarkTitle = info.title }
        }
        item.tags = selectedTags
        try? context.save()
        editing = false
    }
}
