import XCTest
@testable import OmnyCore

final class LinkTitleFetcherTests: XCTestCase {

    // MARK: X/Twitter 推文（oEmbed）

    func testTweetGoesThroughOEmbed() async throws {
        let transport = MockTransport { request in
            let oembed: [String: Any] = [
                "author_name": "Elon Musk",
                "html": #"<blockquote class="twitter-tweet"><p lang="en" dir="ltr">Starship will land on Mars &amp; beyond<br>next year</p>&mdash; Elon Musk (@elonmusk) <a href="https://twitter.com/x/status/1">July 9, 2026</a></blockquote>"#,
            ]
            return (try! JSONSerialization.data(withJSONObject: oembed), 200)
        }
        let fetcher = LinkTitleFetcher(transport: transport)
        let title = await fetcher.fetchTitle(for: URL(string: "https://x.com/elonmusk/status/1234567890")!)

        XCTAssertEqual(title, "Elon Musk：Starship will land on Mars & beyond next year")
        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.host(), "publish.twitter.com", "推文应走 oEmbed 而不是直接抓页面")
        let urlParam = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "url" })?.value
        XCTAssertEqual(urlParam, "https://x.com/elonmusk/status/1234567890")
    }

    func testTweetOEmbedFailureFallsBackToHTML() async {
        // oEmbed 被墙/失败时退回抓页面；页面也只有登录墙标题就用它
        let transport = MockTransport { request in
            if request.url?.host() == "publish.twitter.com" { return (Data(), 403) }
            return (Data("<title>X</title>".utf8), 200)
        }
        let fetcher = LinkTitleFetcher(transport: transport)
        let title = await fetcher.fetchTitle(for: URL(string: "https://x.com/a/status/1")!)
        XCTAssertEqual(title, "X")
    }

    // MARK: 通用网页

    func testOGTitlePreferred() async {
        let html = """
        <html><head>
        <meta property="og:title" content="SwiftData 迁移踩坑记 &amp; 解法" />
        <title>SwiftData 迁移踩坑记 - 某某博客 - 首页</title>
        </head></html>
        """
        let transport = MockTransport { _ in (Data(html.utf8), 200) }
        let fetcher = LinkTitleFetcher(transport: transport)
        let title = await fetcher.fetchTitle(for: URL(string: "https://blog.example.com/post/1")!)
        XCTAssertEqual(title, "SwiftData 迁移踩坑记 & 解法")
    }

    func testTitleTagFallbackWithEntitiesAndWhitespace() async {
        let html = "<html><head><title>\n  你好 &#x4E16;&#30028; &quot;Swift&quot;  \n</title></head></html>"
        let transport = MockTransport { _ in (Data(html.utf8), 200) }
        let fetcher = LinkTitleFetcher(transport: transport)
        let title = await fetcher.fetchTitle(for: URL(string: "https://example.com")!)
        XCTAssertEqual(title, "你好 世界 \"Swift\"")
    }

    func testContentBeforePropertyAttributeOrder() async {
        let html = #"<meta content="倒序属性也能认" property="og:title">"#
        let transport = MockTransport { _ in (Data(html.utf8), 200) }
        let fetcher = LinkTitleFetcher(transport: transport)
        let title = await fetcher.fetchTitle(for: URL(string: "https://example.com")!)
        XCTAssertEqual(title, "倒序属性也能认")
    }

    func testNoTitleReturnsNil() async {
        let transport = MockTransport { _ in (Data("<html><body>纯正文</body></html>".utf8), 200) }
        let fetcher = LinkTitleFetcher(transport: transport)
        let title = await fetcher.fetchTitle(for: URL(string: "https://example.com")!)
        XCTAssertNil(title)
    }

    func testHTTPErrorReturnsNil() async {
        let transport = MockTransport { _ in (Data("<title>error page</title>".utf8), 404) }
        let fetcher = LinkTitleFetcher(transport: transport)
        let title = await fetcher.fetchTitle(for: URL(string: "https://example.com")!)
        XCTAssertNil(title)
    }

    func testLongTitleTruncated() async {
        let long = String(repeating: "长", count: 300)
        let transport = MockTransport { _ in (Data("<title>\(long)</title>".utf8), 200) }
        let fetcher = LinkTitleFetcher(transport: transport)
        let title = await fetcher.fetchTitle(for: URL(string: "https://example.com")!)
        XCTAssertEqual(title?.count, 120)
    }
}
