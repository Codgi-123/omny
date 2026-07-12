import UIKit
import UniformTypeIdentifiers

/// 分享扩展入口：任意 App 的分享面板 → Omny。
/// 只抓取分享的链接/文本写入 App Group 队列，轻提示后立即关闭；
/// 不做解析、不发网络请求（扩展的内存与执行时长受限），入库与 LLM 打标由主 App 完成。
final class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.25)
        Task { await handleShare() }
    }

    private func handleShare() async {
        var urlString: String?
        var texts: [String] = []
        var imageData: Data?

        let inputItems = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        for provider in inputItems.flatMap({ $0.attachments ?? [] }) {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                let loaded = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier)
                if let url = loaded as? URL {
                    urlString = url.absoluteString
                } else if let data = loaded as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) {
                    urlString = url.absoluteString
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                let loaded = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier)
                if let text = loaded as? String {
                    texts.append(text)
                }
            } else if imageData == nil,
                      provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                // 截图/图片：只搬运原始字节，OCR 与入库回主 App 做（扩展不解码大图，省内存）
                imageData = await loadImageData(from: provider)
            }
        }
        // 有些 App 把描述放在 attributedContentText 而不是附件里
        if texts.isEmpty, let attributed = inputItems.first?.attributedContentText?.string,
           !attributed.isEmpty {
            texts.append(attributed)
        }

        let text = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || urlString != nil || imageData != nil else {
            extensionContext?.cancelRequest(withError: NSError(
                domain: "xin.codgi.omny.share", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "分享内容里没有链接、文本或图片"]))
            return
        }

        SharedInbox.append(text: text, urlString: urlString, imageData: imageData)
        showToastThenFinish()
    }

    /// 从 NSItemProvider 取图片字节：优先要原始 data（不解码，省内存），拿不到再退回 loadItem。
    private func loadImageData(from provider: NSItemProvider) async -> Data? {
        let typeID = UTType.image.identifier
        let raw = await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            provider.loadDataRepresentation(forTypeIdentifier: typeID) { data, _ in
                cont.resume(returning: data)
            }
        }
        if let raw { return raw }

        let loaded = try? await provider.loadItem(forTypeIdentifier: typeID)
        if let url = loaded as? URL {
            return try? Data(contentsOf: url)
        } else if let data = loaded as? Data {
            return data
        } else if let image = loaded as? UIImage {
            return image.jpegData(compressionQuality: 0.9)
        }
        return nil
    }

    private func showToastThenFinish() {
        let card = UIView()
        card.backgroundColor = UIColor(red: 1.0, green: 0.992, blue: 0.973, alpha: 1) // 主题卡片色
        card.layer.cornerRadius = 20
        card.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.text = "✓ 已收藏到 Omny"
        label.font = .systemFont(ofSize: 16, weight: .bold)
        label.textColor = UIColor(red: 0.149, green: 0.133, blue: 0.11, alpha: 1)
        label.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(label)
        view.addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            label.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            label.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
        ])

        card.alpha = 0
        UIView.animate(withDuration: 0.15) { card.alpha = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }
}
