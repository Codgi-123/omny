import Foundation

/// 分享扩展 → 主 App 的中转队列（App Group 容器里的 JSON 文件）。
/// 扩展进程内存/时长受限，只做快进快出的排队；解析入库、LLM 打标全部回主 App
/// 前台时完成（RootView 启动/回前台时 drain）。本文件同时编入主 App 与扩展两个 target。
struct SharedItem: Codable {
    var text: String
    /// 扩展侧从 NSItemProvider 拿到的真实 URL（分享网页时通常有；纯文本分享为 nil）
    var urlString: String?
    /// 分享图片（截图等）时图片落进 App Group 的 share-images/ 目录，这里记相对文件名。
    /// JSON 队列只放文件名，避免把大图塞进 JSON；纯文本/链接分享为 nil。
    var imageFile: String?
    var savedAt: Date
}

enum SharedInbox {
    static let appGroupID = "group.xin.codgi.omny"

    private static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }
    private static var queueURL: URL? {
        containerURL?.appendingPathComponent("share-queue.json")
    }
    private static var imageDir: URL? {
        containerURL?.appendingPathComponent("share-images", isDirectory: true)
    }

    /// 排入一条分享。imageData 非空时先落盘再记文件名。
    static func append(text: String, urlString: String? = nil, imageData: Data? = nil) {
        guard let url = queueURL else { return }
        var imageFile: String?
        if let imageData, let dir = imageDir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = UUID().uuidString + ".img"
            if (try? imageData.write(to: dir.appendingPathComponent(name), options: .atomic)) != nil {
                imageFile = name
            }
        }
        var items = load(from: url)
        items.append(SharedItem(text: text, urlString: urlString, imageFile: imageFile, savedAt: .now))
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 读取某条分享暂存的图片数据（主 App drain 时用）。
    static func imageData(for item: SharedItem) -> Data? {
        guard let name = item.imageFile, let dir = imageDir else { return nil }
        return try? Data(contentsOf: dir.appendingPathComponent(name))
    }

    /// 处理完后删掉该条的图片文件，避免容器堆积。
    static func cleanupImage(for item: SharedItem) {
        guard let name = item.imageFile, let dir = imageDir else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
    }

    /// 取走全部排队内容并清空队列（图片文件保留，由调用方处理完再 cleanupImage）
    static func drain() -> [SharedItem] {
        guard let url = queueURL else { return [] }
        let items = load(from: url)
        if !items.isEmpty { try? FileManager.default.removeItem(at: url) }
        return items
    }

    private static func load(from url: URL) -> [SharedItem] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([SharedItem].self, from: data)) ?? []
    }
}
