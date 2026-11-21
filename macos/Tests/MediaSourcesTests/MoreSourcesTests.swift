// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HongguoCore
@testable import MediaSources

final class MoreSourcesTests: XCTestCase {
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [URL] = []
        func add(_ url: URL) { lock.lock(); items.append(url); lock.unlock() }
        var urls: [URL] { lock.lock(); defer { lock.unlock() }; return items }
    }

    static func next(_ json: String) -> Data {
        Data((#"<html><script type="application/json" id="__NEXT_DATA__">"# + json + "</script></html>").utf8)
    }

    // MARK: ReelShort

    static func reelshort(_ url: URL) -> (Int, Data) {
        let path = url.path(percentEncoded: false)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch path {
        case "/":
            return (200, next(#"{"props":{"pageProps":{"fallback":{"/api/ms/hall/webInfo":{"bookShelfList":[{"bookshelf_name":"Trending","books":[{"book_id":"abc1","book_title":"The CEO's Bride!","book_pic":"https://img.example.com/1.jpg","chapter_count":70},{"book_title":"No Id Here"},{"book_title":"the ceo's bride!"}]},{"bookshelf_name":"","books":[]}]}}}}}"#))
        case "/search":
            if query.contains(URLQueryItem(name: "keywords", value: "No Id Here")) {
                return (200, next(#"{"props":{"pageProps":{"books":[{"book_id":"zz9","book_title":"No Id Here"},{"book_id":"zz8","book_title":"No Id Here Too"}]}}}"#))
            }
            return (200, next(#"{"props":{"pageProps":{"books":[]}}}"#))
        case "/movie/the-ceo-s-bride-abc1":
            return (200, next(#"{"props":{"pageProps":{"data":{"book_id":"abc1","book_title":"The CEO's Bride!","online_base":[{"serial_number":2,"chapter_id":"c2","is_lock":1},{"serial_number":1,"chapter_id":"c1","chapter_name":""},{"serial_number":1,"chapter_id":"c1"},{"serial_number":0,"chapter_id":"c0"}]}}}}"#))
        case "/episodes/episode-1-the-ceo-s-bride-abc1-c1":
            XCTAssertTrue(query.contains(URLQueryItem(name: "play_time", value: "1")))
            return (200, next(#"{"props":{"pageProps":{"data":{"serial_number":1,"chapter_id":"c1","video_url":"https://v.example.com/1/index.m3u8"}}}}"#))
        case "/movie/blocked-x1": return (451, Data())
        default: return (404, Data())
        }
    }

    func testReelShort() async throws {
        let log = Log()
        let source = ReelShortSource(fetch: { url, _ in log.add(url); return Self.reelshort(url) })
        XCTAssertEqual(ReelShortSource.slug("The CEO's Bride!"), "the-ceo-s-bride")
        let page = try await source.browse(genre: nil, page: 1)
        XCTAssertEqual(page.genres, [Genre(slug: "shelf-0", label: "Trending")])
        XCTAssertEqual(page.results.map(\.seriesId), ["reelshort:abc1:the-ceo-s-bride", "reelshort:zz9:no-id-here"])
        XCTAssertFalse(page.hasMore)
        let second = try await source.browse(genre: nil, page: 2)
        XCTAssertTrue(second.results.isEmpty)
        do { _ = try await source.browse(genre: "shelf-9", page: 1); XCTFail() } catch let error as HongguoError { XCTAssertEqual(error.kind, .input) }

        let list = try await source.episodes(seriesId: "reelshort:abc1:the-ceo-s-bride")
        XCTAssertEqual(list.episodes.map(\.vid), ["reelshort:abc1:the-ceo-s-bride:1:c1", "reelshort:abc1:the-ceo-s-bride:2:c2"])
        XCTAssertEqual(list.episodes.map(\.title), ["第 1 集", "第 2 集"])
        XCTAssertEqual(list.episodes.map(\.locked), [false, true])
        let play = try await source.playInfo(vid: "reelshort:abc1:the-ceo-s-bride:1:c1", seriesId: nil)
        XCTAssertEqual(play.url.absoluteString, "https://v.example.com/1/index.m3u8")
        do { _ = try await source.playInfo(vid: "reelshort:abc1:the-ceo-s-bride:2:c2", seriesId: nil); XCTFail() } catch let error as HongguoError {
            XCTAssertEqual(error.kind, .previewOnly)
        }
        do { _ = try await source.episodes(seriesId: "reelshort:x1:blocked"); XCTFail() } catch let error as HongguoError {
            XCTAssertEqual(error.message, "ReelShort 当前地区或网络暂不可用（HTTP 451）")
        }
        XCTAssertEqual(try ReelShortSource.resolveSeriesId("https://www.reelshort.com/movie/the-ceo-s-bride-abc1"), "reelshort:abc1:the-ceo-s-bride")
        XCTAssertThrowsError(try ReelShortSource.resolveSeriesId("https://evil.example.com/movie/a-b1"))
    }

    // MARK: DramaBox

    static func dramabox(_ url: URL) -> (Int, Data) {
        switch url.path(percentEncoded: false) {
        case "/browse":
            return (200, next(#"{"props":{"pageProps":{"locale":"en","pageNo":1,"pages":3,"totalNum":60,"bookList":[{"bookId":"11","bookName":"Love","cover":"https://img.example.com/c.jpg","chapterCount":2},{"bookId":"x","bookName":"bad"}]}}}"#))
        case "/search":
            return (200, next(#"{"locale":"en","props":{"pageProps":{"pageNo":1,"totalPage":1,"bookList":[{"bookId":12,"name":"Found"}]}}}"#))
        case "/drama/11":
            return (200, next(#"{"props":{"pageProps":{"locale":"en","bookInfo":{"bookId":"11","bookName":"Love","chapterCount":2},"chapterList":[{"id":"102","index":1,"name":"","unlock":false,"mp4":"https://v.dramaboxdb.com/2.mp4"},{"id":"101","index":0,"name":"Start","unlock":true,"mp4":"https://v.dramaboxdb.com/1.mp4"}]}}}"#))
        case "/drama/13":
            return (200, next(#"{"props":{"pageProps":{"locale":"en","bookInfo":{"bookId":"13","bookName":"Gap","chapterCount":2},"chapterList":[{"id":"1","index":0,"unlock":true,"mp4":"https://evil.example.com/1.mp4"},{"id":"2","index":1}]}}}"#))
        case "/drama/14":
            return (200, next(#"{"props":{"pageProps":{"locale":"zh","bookInfo":{}}}}"#))
        default: return (404, Data())
        }
    }

    func testDramaBox() async throws {
        let source = DramaBoxSource(fetch: { url, _ in Self.dramabox(url) })
        let page = try await source.browse(genre: nil, page: 1)
        XCTAssertEqual(page.results.map(\.seriesId), ["dramabox:11"])
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.total, 60)
        let found = try await source.search("found", page: 1)
        XCTAssertEqual(found.results.first?.title, "Found")
        XCTAssertFalse(found.hasMore)
        do { _ = try await source.browse(genre: "drama", page: 1); XCTFail() } catch let error as HongguoError { XCTAssertEqual(error.kind, .input) }

        let list = try await source.episodes(seriesId: "dramabox:11")
        XCTAssertEqual(list.episodes.map(\.vid), ["dramabox:11:101", "dramabox:11:102"])
        XCTAssertEqual(list.episodes.map(\.title), ["Start", "第 2 集"])
        XCTAssertEqual(list.episodes.map(\.locked), [false, true])
        let play = try await source.playInfo(vid: "dramabox:11:101", seriesId: "dramabox:11")
        XCTAssertEqual(play.url.absoluteString, "https://v.dramaboxdb.com/1.mp4")
        do { _ = try await source.playInfo(vid: "dramabox:11:102", seriesId: nil); XCTFail() } catch let error as HongguoError { XCTAssertEqual(error.kind, .previewOnly) }
        do { _ = try await source.playInfo(vid: "dramabox:13:1", seriesId: nil); XCTFail() } catch let error as HongguoError { XCTAssertEqual(error.kind, .security) }
        do { _ = try await source.episodes(seriesId: "dramabox:14"); XCTFail() } catch let error as HongguoError {
            XCTAssertEqual(error.message, "DramaBox 官网数据或语言不匹配")
        }
        XCTAssertEqual(try DramaBoxSource.resolveSeriesId("https://www.dramaboxdb.com/movie/42/x"), "dramabox:42")
        XCTAssertThrowsError(try DramaBoxSource.resolveSeriesId("http://www.dramabox.com/drama/42"))
    }

    // MARK: Custom

    static let uuid = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"

    static func cms(_ url: URL) -> Data {
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["ac"], "detail")
        XCTAssertEqual(query["at"], "json")
        if query["ids"] == "7" {
            return Data(#"{"code":1,"list":[{"vod_id":7,"vod_name":"剧","vod_play_from":"a$$$b","vod_play_url":"第1集$https://a.example.com/1.m3u8#第2集$https://a.example.com/2.m3u8$$$1$https://b.example.com/1.mp4#2$https://b.example.com/2.mp4#2集$https://b.example.com/2b.mp4#3$ftp://b.example.com/3.mp4"}]}"#.utf8)
        }
        if query["ids"] == "8" {
            return Data(#"{"code":1,"list":[{"vod_id":8,"vod_name":"付费","vod_points_play":5,"vod_play_url":"1$https://a.example.com/1.mp4"}]}"#.utf8)
        }
        return Data(#"{"code":1,"page":"\#(query["pg"] ?? "1")","pagecount":2,"total":30,"class":[{"type_id":1,"type_name":"短剧"},{"type_id":"x","type_name":"坏"}],"list":[{"vod_id":"7","vod_name":"<b>剧</b>","vod_pic":"https://img.example.com/7.jpg","type_name":"短剧"},{"vod_id":"no","vod_name":"x"}]}"#.utf8)
    }

    func testCustomSource() async throws {
        let draft = try CustomSource.validate(CustomSourceConfig(name: " 我的源 ", url: "https://cms.example.com#x"))
        XCTAssertEqual(draft.url, "https://cms.example.com/api.php/provide/vod/")
        XCTAssertThrowsError(try CustomSource.validate(CustomSourceConfig(name: "a", url: "http://192.168.1.2/api")))
        XCTAssertThrowsError(try CustomSource.validate(CustomSourceConfig(name: "", url: "https://cms.example.com")))
        let tested = try await CustomSource.test(draft, fetch: { Self.cms($0) })
        XCTAssertEqual(tested.count, 2)
        XCTAssertEqual(tested.genres, [Genre(slug: "1", label: "短剧")])

        let stored = Store(CustomSourceConfig(id: Self.uuid, name: "我的源", url: draft.url))
        let source = CustomSource(config: stored.value!, current: { id in id == Self.uuid ? stored.value : nil }, fetch: { Self.cms($0) })
        let page = try await source.browse(genre: "1", page: 1)
        XCTAssertEqual(page.results.map(\.seriesId), ["custom:\(Self.uuid):7"])
        XCTAssertEqual(page.results.first?.title, "剧")
        XCTAssertTrue(page.hasMore)
        do { _ = try await source.browse(genre: nil, page: 2) } catch { XCTFail("\(error)") }

        let list = try await source.episodes(seriesId: "custom:\(Self.uuid):7")
        XCTAssertEqual(list.episodes.map(\.vid), ["custom:\(Self.uuid):7:1:0", "custom:\(Self.uuid):7:1:1"], "longest line wins, 第2集/2集 collapse")
        let candidates = try await source.playCandidates(vid: "custom:\(Self.uuid):7:1:1", seriesId: nil)
        XCTAssertEqual(candidates.map(\.url.absoluteString), ["https://b.example.com/2.mp4", "https://a.example.com/2.m3u8", "https://b.example.com/2b.mp4"])
        XCTAssertEqual(candidates.first?.referer, "https://cms.example.com/")
        do { _ = try await source.playInfo(vid: "custom:\(Self.uuid):8:0:0", seriesId: nil); XCTFail() } catch let error as HongguoError { XCTAssertEqual(error.kind, .previewOnly) }

        stored.value?.enabled = false
        do { _ = try await source.search("剧", page: 1); XCTFail() } catch let error as HongguoError { XCTAssertEqual(error.message, "该自定义源已禁用或删除") }
        stored.value?.enabled = true
        stored.value?.url = "https://other.example.com/api.php/provide/vod/"
        do { _ = try await source.search("剧", page: 1); XCTFail() } catch let error as HongguoError { XCTAssertEqual(error.message, "来源配置已变更，请重新加载") }
    }

    final class Store: @unchecked Sendable {
        var value: CustomSourceConfig?
        init(_ value: CustomSourceConfig) { self.value = value }
    }

    func testSettingsForSources() throws {
        var settings = SourceSettings()
        XCTAssertEqual(settings.mediaSources.map(\.id), ["hongguo", "xifan", "hema"])
        XCTAssertThrowsError(try settings.setBuiltinSource("hongguo", enabled: false))
        try settings.setBuiltinSource("reelshort", enabled: true)
        try settings.setBuiltinSource("hema", enabled: false)
        let saved = try settings.saveCustomSource(CustomSourceConfig(name: "源", url: "https://cms.example.com"))
        XCTAssertFalse(saved.id.isEmpty)
        XCTAssertEqual(settings.mediaSources.map(\.id), ["hongguo", "xifan", "reelshort", "custom:\(saved.id)"])

        let data = try JSONEncoder().encode(settings)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object["customSources"] = (object["customSources"] as! [Any]) + [["name": "坏", "url": "http://127.0.0.1/"], 5]
        let decoded = try JSONDecoder().decode(SourceSettings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.customSources, [saved])
        XCTAssertEqual(decoded.builtinSources, ["reelshort": true, "hema": false])

        let snapshot = decoded
        XCTAssertNil(try MediaSources.source(for: "7123456789", settings: { snapshot }))
        XCTAssertEqual(try MediaSources.source(for: "reelshort:a:b", settings: { snapshot })?.id, "reelshort")
        XCTAssertThrowsError(try MediaSources.source(for: "hema:1", settings: { snapshot }))
        XCTAssertThrowsError(try MediaSources.source(for: "dramabox:1", settings: { snapshot }))
        XCTAssertEqual(try MediaSources.source(for: "custom:\(saved.id):1", settings: { snapshot })?.label, "源")
        try settings.removeCustomSource(id: saved.id)
        XCTAssertTrue(settings.customSources.isEmpty)
    }

    func testStoreTakesOlderLibrarySettingsOnceThenKeepsItsOwn() throws {
        let suite = "MediaSourcesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = dir.appendingPathComponent("library.json")
        let legacy: [String: Any] = ["version": 1, "settings": ["autoNext": true, "builtinSources": ["dramabox": true],
                                     "customSources": [["id": "0f8fad5b-d9cb-469f-a165-70867728950e", "name": "源", "url": "https://cms.example.com", "enabled": true]]]]
        try JSONSerialization.data(withJSONObject: legacy).write(to: library)

        let first = SourceSettingsStore(defaults: defaults, legacyLibrary: library)
        XCTAssertEqual(first.value.builtinSources, ["dramabox": true])
        XCTAssertEqual(first.value.customSources.map(\.name), ["源"])
        first.value.builtinSources["dramabox"] = false

        try FileManager.default.removeItem(at: library)
        let second = SourceSettingsStore(defaults: defaults, legacyLibrary: library)
        XCTAssertEqual(second.value.builtinSources, ["dramabox": false], "the saved value wins over library.json")
        XCTAssertEqual(second.value.customSources.count, 1)
    }
}
