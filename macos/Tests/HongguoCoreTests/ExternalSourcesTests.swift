// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HongguoCore

final class ExternalSourcesTests: XCTestCase {
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [URL] = []
        func add(_ url: URL) { lock.lock(); items.append(url); lock.unlock() }
        var urls: [URL] { lock.lock(); defer { lock.unlock() }; return items }
    }

    func testSourceSwitches() {
        XCTAssertEqual(MediaSources.enabled([:]).map(\.id), ["hongguo", "xifan", "hema"])
        XCTAssertEqual(MediaSources.enabled(["xifan": false, "hongguo": false, "dramabox": true]).map(\.id), ["hongguo", "hema", "dramabox"])
        XCTAssertEqual(MediaSources.sourceId(of: "xifan:a:b"), "xifan")
        XCTAssertEqual(MediaSources.sourceId(of: "hema:1:2"), "hema")
        XCTAssertEqual(MediaSources.sourceId(of: "7123456789"), "hongguo")
        XCTAssertEqual(MediaSources.httpsURL("http://cdn.example.com/a.mp4"), "")
        XCTAssertEqual(MediaSources.httpsURL("https://u:p@cdn.example.com/a.mp4"), "")
        XCTAssertEqual(MediaSources.httpsURL("https://127.0.0.1/a.mp4"), "")
        XCTAssertEqual(MediaSources.httpsURL("https://cdn.example.com/a.mp4"), "https://cdn.example.com/a.mp4")
        XCTAssertEqual(MediaSources.plainText(" <b>霸总</b> "), "霸总")
    }

    // MARK: 西饭

    static func xifanJSON(_ url: URL) -> String {
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        switch (url.path(percentEncoded: false), query["reqType"]) {
        case ("/xifan/drama/portalPage", "duanjuCategory"):
            return #"{"ret":0,"result":{"elements":[{"contents":[{"categoryItemVo":{"subCategories":[{"categoryId":3,"oppoCategory":"古装","version":2},{"categoryId":5,"oppoCategory":"都市"},{"categoryId":0,"oppoCategory":"坏"}]}}]}]}}"#
        case ("/xifan/drama/portalPage", "aggregationPage"):
            return #"{"ret":0,"result":{"hasMore":true,"elements":[{"contents":[{"duanjuVo":{"source":"jiuzhou","duanjuId":"253","title":"天龙战神","coverImageUrl":"https://img.example.com/c.jpg","total":80,"categories":["都市","战神"]}},{"duanjuVo":{"source":"bad id","duanjuId":"1","title":"x"}},{"duanjuVo":{"source":"jiuzhou","duanjuId":"253","title":"重复"}}]}]}}"#
        case ("/xifan/search/getSearchList", _):
            return #"{"ret":0,"result":{"hasMore":false,"elements":[{"contents":[{"duanjuVo":{"source":"jiuzhou","duanjuId":"9","title":"<em>搜</em>到","coverImageUrl":"http://img.example.com/x.jpg"}}]}]}}"#
        case ("/xifan/drama/getDuanjuInfo", _):
            return #"{"ret":0,"result":{"source":"jiuzhou","duanjuId":"253","title":"天龙战神","coverImageUrl":"https://img.example.com/c.jpg","episodeList":[{"episodeId":"e2","index":2,"title":"第二集","unlock":false,"playUrl":"https://v.example.com/2.mp4"},{"episodeId":"e1","index":1,"title":"爱归良辰","unlock":true,"playUrl":"https://v.example.com/1.mp4"},{"episodeId":"e3","index":3,"unlock":true,"playUrl":"http://v.example.com/3.mp4"}]}}"#
        default: return #"{"ret":1}"#
        }
    }

    func testXifanBrowseSearchEpisodesAndPlay() async throws {
        let log = Log()
        let source = XifanSource(fetch: { url in log.add(url); return Data(Self.xifanJSON(url).utf8) })
        let page = try await source.browse(genre: nil, page: 2)
        XCTAssertEqual(page.genres.map(\.label), ["古装", "都市"])
        XCTAssertEqual(page.results.map(\.seriesId), ["xifan:jiuzhou:253"])
        XCTAssertEqual(page.results.first?.tags, ["都市", "战神"])
        XCTAssertTrue(page.hasMore)
        let browse = log.urls.last.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        XCTAssertTrue(browse.contains(URLQueryItem(name: "offset", value: "30")))
        XCTAssertTrue(browse.contains(URLQueryItem(name: "categoryNames", value: "都市")))
        XCTAssertTrue(browse.contains(URLQueryItem(name: "version", value: "2001001")))
        do { _ = try await source.browse(genre: "999-ff", page: 1); XCTFail() } catch let error as HongguoError { XCTAssertEqual(error.kind, .input) }

        let found = try await source.search(" 搜 ", page: 1)
        XCTAssertEqual(found.results.first?.title, "搜到")
        XCTAssertEqual(found.results.first?.cover, "")
        XCTAssertFalse(found.hasMore)

        let list = try await source.episodes(seriesId: "xifan:jiuzhou:253")
        XCTAssertEqual(list.episodes.map(\.vid), ["xifan:jiuzhou:253:e1", "xifan:jiuzhou:253:e2", "xifan:jiuzhou:253:e3"])
        XCTAssertEqual(list.episodes.map(\.locked), [false, true, false])
        XCTAssertEqual(list.episodes.first?.title, "", "a verified upstream title conflict is dropped")
        XCTAssertEqual(list.webAccessibleEpisodes, 2)

        let play = try await source.playInfo(vid: "xifan:jiuzhou:253:e1", seriesId: "xifan:jiuzhou:253")
        XCTAssertEqual(play.url.absoluteString, "https://v.example.com/1.mp4")
        do { _ = try await source.playInfo(vid: "xifan:jiuzhou:253:e2", seriesId: nil); XCTFail() } catch let error as HongguoError {
            XCTAssertEqual(error.kind, .previewOnly)
            XCTAssertTrue(error.message.contains("第 2 集"))
        }
        do { _ = try await source.playInfo(vid: "xifan:jiuzhou:253:e3", seriesId: nil); XCTFail() } catch let error as HongguoError { XCTAssertEqual(error.kind, .upstream) }
        do { _ = try await source.playInfo(vid: "xifan:jiuzhou:253:e1", seriesId: "xifan:jiuzhou:254"); XCTFail() } catch let error as HongguoError { XCTAssertEqual(error.kind, .input) }
        do { _ = try await source.episodes(seriesId: "xifan:../x:1"); XCTFail() } catch let error as HongguoError { XCTAssertEqual(error.kind, .input) }
    }

    func testXifanFailuresAreFriendly() async {
        let down = XifanSource(fetch: { _ in throw URLError(.cannotConnectToHost) })
        do { _ = try await down.search("a", page: 1); XCTFail() } catch let error as HongguoError {
            XCTAssertEqual(error.message, "西饭来源暂不可用，请稍后重试")
        } catch { XCTFail("\(error)") }
        let bad = XifanSource(fetch: { _ in Data(#"{"ret":0,"result":{"source":"other","duanjuId":"253","episodeList":[]}}"#.utf8) })
        do { _ = try await bad.episodes(seriesId: "xifan:jiuzhou:253"); XCTFail() } catch let error as HongguoError {
            XCTAssertEqual(error.kind, .format)
        } catch { XCTFail("\(error)") }
    }

    // MARK: 河马

    static func next(_ props: String) -> String {
        #"<html><script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":"# + props + #"}}</script>"#
    }

    static func hemaResponse(_ url: URL, _ body: Data?) -> String {
        switch url.path(percentEncoded: false) {
        case "/browse":
            return next(#"{"typeThreeList":[{"typeThreeIds":[0],"name":"全部"},{"typeThreeIds":[12,13],"name":"逆袭"},{"typeThreeIds":["x"],"name":"坏"}],"bookList":[{"bookId":"41","bookName":"首页剧","coverWap":"https://img.example.com/1.jpg","totalChapterNum":60,"bookTypeThree":[{"name":"逆袭"}]}],"page":1,"typeThreeId":0}"#)
                + #"<a href="/browse/0/2">下一页</a>"#
        case "/browse/12-13/2":
            return next(#"{"bookList":[{"bookId":42,"bookName":"第二页"}],"page":2,"typeThreeId":"12-13"}"#)
        case "/seo/video/6007":
            return #"{"retCode":0,"data":{"isMore":1,"totalSize":31,"bookList":[{"bookId":"43","bookName":"搜到"}]}}"#
        case "/drama/41":
            return next(#"{"bookInfoVo":{"bookId":"41","bookName":"首页剧","coverWap":"https://img.example.com/1.jpg"},"chapterList":[{"chapterId":"2","chapterIndex":2,"chapterName":"二","isCharge":"1","chapterVideoVo":{"mp4":"https://v.example.com/2.mp4"}},{"chapterId":"1","chapterIndex":1,"chapterName":"一","isCharge":"0","bookId":"41","chapterVideoVo":{"mp4720p":"http://v.example.com/1-720.mp4","mp4":"https://v.example.com/1.mp4"}}]}"#)
        case "/drama/44":
            return next(#"{"bookInfoVo":{"bookId":"41"},"chapterList":[]}"#)
        default: return "<html></html>"
        }
    }

    func testHemaBrowseSearchEpisodesAndPlay() async throws {
        let log = Log()
        let bodies = Log()
        let source = HemaSource(fetch: { url, body in
            log.add(url)
            if let body, let text = String(data: body, encoding: .utf8) { bodies.add(URL(string: "data:" + (text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""))!) }
            return Data(Self.hemaResponse(url, body).utf8)
        })
        let first = try await source.browse(genre: nil, page: 1)
        XCTAssertEqual(log.urls.count, 1, "the directory page doubles as the first page")
        XCTAssertEqual(first.genres, [Genre(slug: "12-13", label: "逆袭")])
        XCTAssertEqual(first.results.first?.seriesId, "hema:41")
        XCTAssertEqual(first.results.first?.tags, ["逆袭"])
        XCTAssertTrue(first.hasMore)
        let second = try await source.browse(genre: "12-13", page: 2)
        XCTAssertEqual(second.results.map(\.seriesId), ["hema:42"])
        XCTAssertFalse(second.hasMore)
        XCTAssertEqual(log.urls.count, 2, "genres stay cached")
        do { _ = try await source.browse(genre: "99", page: 1); XCTFail() } catch let error as HongguoError { XCTAssertEqual(error.kind, .input) }

        let found = try await source.search("搜", page: 1)
        XCTAssertEqual(found.results.map(\.seriesId), ["hema:43"])
        XCTAssertTrue(found.hasMore)
        XCTAssertEqual(found.total, 31)
        XCTAssertEqual(bodies.urls.count, 1)

        let list = try await source.episodes(seriesId: "hema:41")
        XCTAssertEqual(list.episodes.map(\.vid), ["hema:41:1", "hema:41:2"])
        XCTAssertEqual(list.episodes.map(\.locked), [false, true])
        let play = try await source.playInfo(vid: "hema:41:1", seriesId: "hema:41")
        XCTAssertEqual(play.url.absoluteString, "https://v.example.com/1.mp4", "a plain-http 720p URL falls back to the HTTPS mp4")
        XCTAssertEqual(play.referer, "https://www.kuaikaw.cn/")
        do { _ = try await source.playInfo(vid: "hema:41:2", seriesId: nil); XCTFail() } catch let error as HongguoError {
            XCTAssertEqual(error.kind, .previewOnly)
        }
        do { _ = try await source.episodes(seriesId: "hema:44"); XCTFail() } catch let error as HongguoError { XCTAssertEqual(error.kind, .format) }
        do { _ = try await source.playInfo(vid: "hema:41", seriesId: nil); XCTFail() } catch let error as HongguoError { XCTAssertEqual(error.kind, .input) }
    }
}
