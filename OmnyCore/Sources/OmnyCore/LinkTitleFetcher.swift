import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 链接标题抓取：分享面板常只给裸 URL（X/微博等 App 尤其如此），入库后由主 App 补标题。
/// - X/Twitter 推文：走公开 oEmbed 接口（x.com 页面是 JS 壳，直接抓只有登录墙），
///   标题拼成「作者：推文内容」
/// - 其他网页：GET 页面 HTML，优先 og:title，退回 <title>
/// 失败一律返回 nil（无网/被墙/解析不出），收藏照常入库，界面退回显示域名。
public struct LinkTitleFetcher: Sendable {
    public var transport: any HTTPTransport

    public init(transport: any HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    public func fetchTitle(for url: URL) async -> String? {
        if let tweetTitle = await fetchTweetTitle(for: url) { return tweetTitle }
        return await fetchHTMLTitle(for: url)
    }

    // MARK: X/Twitter oEmbed

    static let tweetHosts: Set<String> = ["x.com", "www.x.com", "twitter.com",
                                          "www.twitter.com", "mobile.twitter.com"]

    /// 推文链接返回「作者：内容」，非推文链接返回 nil（落到通用抓取）
    func fetchTweetTitle(for url: URL) async -> String? {
        guard let host = url.host()?.lowercased(), Self.tweetHosts.contains(host),
              url.path().contains("/status/") else { return nil }

        var components = URLComponents(string: "https://publish.twitter.com/oembed")!
        components.queryItems = [
            URLQueryItem(name: "url", value: url.absoluteString),
            URLQueryItem(name: "omit_script", value: "true"),
        ]
        guard let oembedURL = components.url,
              let (data, response) = try? await transport.send(URLRequest(url: oembedURL)),
              response.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let author = json["author_name"] as? String
        // html 形如 <blockquote…><p …>推文内容</p>&mdash; 作者 (@id) <a …>日期</a></blockquote>
        let text = (json["html"] as? String).flatMap(Self.extractTweetText(fromOEmbedHTML:))

        switch (author, text) {
        case (let author?, let text?): return Self.clean("\(author)：\(text)")
        case (nil, let text?): return Self.clean(text)
        case (let author?, nil): return Self.clean("\(author) 的推文")
        default: return nil
        }
    }

    static func extractTweetText(fromOEmbedHTML html: String) -> String? {
        guard let m = html.firstMatch(of: /<p[^>]*>([\s\S]*?)<\/p>/.ignoresCase()) else {
            return nil
        }
        let stripped = String(m.output.1)
            .replacingOccurrences(of: "<br>", with: " ")
            .replacingOccurrences(of: "<br/>", with: " ")
            .replacing(/<[^>]+>/, with: "")
        let decoded = decodeHTMLEntities(stripped)
        return decoded.isEmpty ? nil : decoded
    }

    // MARK: 通用网页

    func fetchHTMLTitle(for url: URL) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        // 不少站点对无 UA 的请求返回精简页/拒绝
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")

        guard let (data, response) = try? await transport.send(request),
              response.statusCode == 200 else { return nil }
        let html = String(decoding: data.prefix(512 * 1024), as: UTF8.self)

        // og:title 优先（<title> 常带站点名后缀），属性顺序两种写法都兼容
        if let m = html.firstMatch(of:
            /<meta[^>]+(?:property|name)=["']og:title["'][^>]*content=["']([^"']*)["']/.ignoresCase()) {
            if let title = Self.clean(Self.decodeHTMLEntities(String(m.output.1))) { return title }
        }
        if let m = html.firstMatch(of:
            /<meta[^>]+content=["']([^"']*)["'][^>]*(?:property|name)=["']og:title["']/.ignoresCase()) {
            if let title = Self.clean(Self.decodeHTMLEntities(String(m.output.1))) { return title }
        }
        if let m = html.firstMatch(of: /<title[^>]*>([\s\S]*?)<\/title>/.ignoresCase()) {
            return Self.clean(Self.decodeHTMLEntities(String(m.output.1)))
        }
        return nil
    }

    // MARK: 工具

    /// 压缩空白、去首尾、限长；清完为空返回 nil
    static func clean(_ raw: String) -> String? {
        let collapsed = raw.replacing(/\s+/, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(120))
    }

    static func decodeHTMLEntities(_ string: String) -> String {
        var result = string
        let named = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                     "&#39;": "'", "&apos;": "'", "&nbsp;": " ",
                     "&mdash;": "—", "&ndash;": "–", "&hellip;": "…"]
        for (entity, char) in named {
            result = result.replacingOccurrences(of: entity, with: char)
        }
        // 数字实体：&#20320; / &#x4F60;
        while let m = result.firstMatch(of: /&#(x?)([0-9a-fA-F]+);/) {
            let isHex = !m.output.1.isEmpty
            let replacement = UInt32(m.output.2, radix: isHex ? 16 : 10)
                .flatMap(Unicode.Scalar.init)
                .map(String.init) ?? ""
            result.replaceSubrange(m.range, with: replacement)
        }
        return result
    }
}
