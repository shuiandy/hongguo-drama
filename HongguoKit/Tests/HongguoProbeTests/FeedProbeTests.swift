import XCTest
@testable import HongguoCore
@testable import HongguoPlayback

/// Live, read-only probes of the App catalogue endpoints. Skipped unless HONGGUO_PROBE names
/// a probe, so `swift test` never touches the network. Raw responses go to captures/ (ignored
/// by git); only shapes are printed.
final class FeedProbeTests: XCTestCase {

    private var probe: String { ProcessInfo.processInfo.environment["HONGGUO_PROBE"] ?? "" }
    private var captures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("captures")
    }

    private func body(scene: String, genre: String, sort: [String], offset: Int = 0, sessionId: String = "",
                      panel: Bool = true, limit: Int = 15) -> Data {
        let object: [String: Any] = [
            "filter_ids": "", "req_scene": scene, "offset": offset, "need_selector_panel": panel, "limit": limit,
            "select_items": ["genre": genre.isEmpty ? [String]() : [genre], "sort": sort, "category_dim_theme": [String](),
                             "category_dim_role": [String](), "category_dim_epoch": [String](), "gender": [String](),
                             "online_time": [String](), "creation_status": [String]()],
            "session_id": sessionId, "req_type": offset > 0 ? "only_content" : "default", "client_req_type": 3,
        ]
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func describe(_ name: String, _ payload: JSONValue) {
        let data = payload["data"]
        print("PROBE \(name): code=\(payload["code"].idString ?? "?") dataKeys=\(data.object?.keys.sorted() ?? [])")
        print("PROBE \(name): has_more=\(String(describing: data["has_more"].bool)) next_offset=\(data["next_offset"].idString ?? "nil") session_id.len=\((data["session_id"].idString ?? "").count)")
        for row in data["selector_rows"].array ?? [] {
            let items = (row["items"].array ?? []).map { "\($0["selector_item_id"].idString ?? "?")=\($0["show_name"].string ?? "")\($0["is_selected"].bool == true ? "*" : "")" }
            print("PROBE \(name): selector \(row["type"].string ?? "?") -> \(items.prefix(14))")
        }
        let videos = data["video_data"].array ?? []
        print("PROBE \(name): videos=\(videos.count) keys=\(videos.first?.object?.keys.sorted() ?? [])")
        for video in videos.prefix(4) {
            print("PROBE \(name):   \(video["series_id"].idString ?? "?") type=\(video["content_type"].idString ?? "?") eps=\(video["episode_cnt"].idString ?? "?") \(video["title"].string ?? video["series_title"].string ?? "")")
        }
    }

    private func save(_ name: String, _ payload: JSONValue) throws {
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: Self.plain(payload), options: [.prettyPrinted, .sortedKeys])
            .write(to: captures.appendingPathComponent("\(name).json"))
    }

    static func plain(_ value: JSONValue) -> Any {
        if let object = value.object { return object.mapValues(plain) }
        if let array = value.array { return array.map(plain) }
        if let string = value.string { return string }
        if let bool = value.bool { return bool }
        if let number = value.number { return number }
        return NSNull()
    }

    /// HONGGUO_PROBE=landpage HONGGUO_PROBE_ARGS="scene|genre|sort|offset|session|name"
    func testLandpage() async throws {
        try XCTSkipUnless(probe == "landpage", "set HONGGUO_PROBE=landpage to run this live probe")
        let args = (ProcessInfo.processInfo.environment["HONGGUO_PROBE_ARGS"] ?? "default|short_play|hot_score|0||landpage").components(separatedBy: "|")
        let sort = args[2].isEmpty ? [String]() : [args[2]]
        let payload = try await AppCatalogueAccess.landpage(body: body(scene: args[0], genre: args[1], sort: sort,
                                                                       offset: Int(args[3]) ?? 0, sessionId: args[4]))
        try save(args[5], payload)
        describe(args[5], payload)
    }
    /// HONGGUO_PROBE=firstvid HONGGUO_PROBE_ARGS="<seriesId>|<vid>": is the row's `vid` episode 1?
    func testFirstVid() async throws {
        try XCTSkipUnless(probe == "firstvid", "set HONGGUO_PROBE=firstvid to run this live probe")
        let args = (ProcessInfo.processInfo.environment["HONGGUO_PROBE_ARGS"] ?? "").components(separatedBy: "|")
        let list = try await SeriesService().episodes(seriesId: args[0])
        let match = list.episodes.first { $0.vid == args[1] }
        print("PROBE firstvid: total=\(list.total) first=\(list.episodes.first?.vid ?? "?") rowVidIsEpisode=\(match.map { String($0.index) } ?? "none")")
    }

    /// HONGGUO_PROBE=bookmall HONGGUO_PROBE_ARGS="tab_type|offset|session_id|host|name"
    func testBookMallTab() async throws {
        try XCTSkipUnless(probe == "bookmall", "set HONGGUO_PROBE=bookmall to run this live probe")
        let rawArgs = (ProcessInfo.processInfo.environment["HONGGUO_PROBE_ARGS"] ?? "8|0|||bookmall-tab8").components(separatedBy: "|")
        let tabType = rawArgs[safe: 0] ?? "8"
        let offset = rawArgs[safe: 1] ?? "0"
        let sessionId = rawArgs[safe: 2] ?? ""
        let host = rawArgs[safe: 3].flatMap { $0.isEmpty ? nil : $0 }
        let name = rawArgs[safe: 4].flatMap { $0.isEmpty ? nil : $0 } ?? "bookmall-tab\(tabType)"
        let bottomTabType = rawArgs[safe: 5].flatMap { $0.isEmpty ? nil : $0 } ?? "7"
        var values: [(String, String)] = [
            ("tab_type", tabType),
            ("offset", offset),
            ("client_req_type", offset == "0" ? "0" : "2"),
            ("bottom_tab_type", bottomTabType),
        ]
        if !sessionId.isEmpty { values.append(("session_id", sessionId)) }
        let payload = try await AppBookMallAccess.tab(values: values, host: host)
        try save(name, payload)
        let data = payload["data"]
        print("PROBE \(name): code=\(payload["code"].idString ?? "?") msg=\(payload["message"].string ?? "") dataKeys=\(data.object?.keys.sorted() ?? [])")
        let items = data["tab_item"].array ?? []
        print("PROBE \(name): tab_item.count=\(items.count)")
        for item in items {
            let cells = item["cell_data"].array ?? []
            print("PROBE \(name): tab=\(item["tab_type"].idString ?? "?") title=\(item["title"].string ?? "") has_more=\(String(describing: item["has_more"].bool)) next_offset=\(item["next_offset"].idString ?? "?") session_id.len=\((item["session_id"].string ?? "").count) cell_data=\(cells.count)")
            for cell in cells.prefix(5) {
                print("PROBE \(name):   cell keys=\(cell.object?.keys.sorted() ?? []) cell_type=\(cell["cell_type"].idString ?? "?")")
            }
        }
    }

    /// HONGGUO_PROBE=cellchange HONGGUO_PROBE_ARGS="cell_id|offset|session_id|tab_type|name"
    func testCellChange() async throws {
        try XCTSkipUnless(probe == "cellchange", "set HONGGUO_PROBE=cellchange to run this live probe")
        let rawArgs = (ProcessInfo.processInfo.environment["HONGGUO_PROBE_ARGS"] ?? "6952850996422770718|6||8|cellchange-8").components(separatedBy: "|")
        var values: [(String, String)] = [
            ("cell_id", rawArgs[safe: 0] ?? "6952850996422770718"),
            ("offset", rawArgs[safe: 1] ?? "6"),
            ("tab_type", rawArgs[safe: 3] ?? "8"),
            ("change_type", "1"),
        ]
        if let sid = rawArgs[safe: 2], !sid.isEmpty { values.append(("session_id", sid)) }
        let name = rawArgs[safe: 4] ?? "cellchange"
        let payload = try await AppCatalogueAccess.cellChange(values: values)
        try save(name, payload)
        let data = payload["data"]
        print("PROBE \(name): code=\(payload["code"].idString ?? "?") msg=\(payload["message"].string ?? "") dataKeys=\(data.object?.keys.sorted() ?? [])")
        print("PROBE \(name): has_more=\(String(describing: data["has_more"].bool)) next_offset=\(data["next_offset"].idString ?? "?") cell_data=\((data["cell_data"].array ?? []).count)")
    }

    /// `HONGGUO_PROBE=feedcontract swift test --filter FeedProbeTests/testFeedContractLive`:
    /// Verifies that both anonymous (`AppBookMallAccess`) and `accountRead` signer profiles return
    /// the exact requested `tab_type` under `bottom_tab_type=7`, paginate cleanly through
    /// `cell/change/v` (including 3+ MiB comic payloads), and keep 真人剧 / 漫剧 pure.
    func testFeedContractLive() async throws {
        try XCTSkipUnless(probe == "feedcontract", "set HONGGUO_PROBE=feedcontract to run this live probe")
        let transport = AppTransport(http: .shared)
        let (identity, dToken) = try await PersistentAppDevice.dataIdentity(transport: transport)

        for channel in BookMallFeedChannel.allCases {
            // 1. Anonymous path (page 1 + page 2).
            // Note: tab 16 (推荐) returns 3 cards on page 1 and occasionally fills all 3 with UGC
            // promo clips (content_type=1001, filtered out); its cursor must still advance to page 2.
            let p1 = try await BookMallFeed.page(channel: channel, cursor: .first)
            if channel != .recommend {
                XCTAssertFalse(p1.entries.isEmpty, "anonymous page 1 empty for \(channel.rawValue)")
            }
            let cursor = try XCTUnwrap(p1.next, "anonymous page 1 missing cursor for \(channel.rawValue)")
            let p2 = try await BookMallFeed.page(channel: channel, cursor: cursor)
            XCTAssertFalse(p2.entries.isEmpty, "anonymous page 2 empty for \(channel.rawValue)")

            // 2. Account signer profile (verifies version_code=74532 on accountHost without touching Keychain)
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let signed = try AppLegacySigner.shared.accountRead(
                path: "/reading/bookapi/bookmall/tab/v/",
                values: BookMallFeed.tabQuery(channel: channel),
                identity: identity,
                dToken: dToken,
                nowMillis: now
            )
            let rawAcc = try await transport.requestJSON(signed.url, headers: signed.headers, deadline: Date().addingTimeInterval(12))
            let accTabs = (rawAcc["data"]["tab_item"].array ?? []).compactMap { AppFeed.integer($0["tab_type"]) }
            XCTAssertTrue(accTabs.contains(channel.tabType), "accountRead missing tab_type=\(channel.tabType), got \(accTabs)")
            let accP1 = try BookMallFeed.parseTab(rawAcc, channel: channel)
            if channel != .recommend {
                XCTAssertFalse(accP1.entries.isEmpty, "accountRead page 1 empty for \(channel.rawValue)")
            }
            XCTAssertNotNil(accP1.next, "accountRead page 1 missing cursor for \(channel.rawValue)")

            for (stage, entries) in [("anon-p1", p1.entries), ("anon-p2", p2.entries), ("acc-p1", accP1.entries)] {
                for entry in entries {
                    XCTAssertFalse(entry.firstVid.isEmpty, "\(channel.rawValue) \(stage) missing firstVid")
                    XCTAssertFalse(entry.series.title.isEmpty, "\(channel.rawValue) \(stage) missing title")
                    switch channel {
                    case .liveAction:
                        XCTAssertEqual(entry.contentType, 1, "\(channel.rawValue) \(stage) leaked content_type=\(entry.contentType) title=\(entry.series.title)")
                        XCTAssertEqual(entry.aiUsageType, 0, "\(channel.rawValue) \(stage) leaked ai_usage_type=\(entry.aiUsageType) title=\(entry.series.title)")
                    case .comic:
                        XCTAssertEqual(entry.contentType, 1004, "\(channel.rawValue) \(stage) leaked content_type=\(entry.contentType) title=\(entry.series.title)")
                    case .recommend:
                        XCTAssertTrue([1, 1004].contains(entry.contentType))
                    }
                }
            }
            print("PROBE feedcontract \(channel.rawValue)(tab=\(channel.tabType)): anonP1=\(p1.entries.count) anonP2=\(p2.entries.count) accP1=\(accP1.entries.count) first='\(p1.entries.first?.series.title ?? "")'")
        }
    }

    /// `HONGGUO_PROBE=replies swift test --filter FeedProbeTests/testCommentRepliesLive`:
    /// Finds a live episode comment with `replyCount > 0` and fetches two pages of replies.
    func testCommentRepliesLive() async throws {
        try XCTSkipUnless(probe == "replies", "set HONGGUO_PROBE=replies to run this live probe")
        let feed = try await BookMallFeed.page(channel: .liveAction, cursor: .first)
        var tested = false
        for entry in feed.entries.prefix(5) where !entry.firstVid.isEmpty {
            let comments = try await EpisodeSocialService.commentsPage(seriesId: entry.series.seriesId, vid: entry.firstVid, count: 20)
            guard let target = comments.comments.first(where: { $0.replyCount >= 6 }) ?? comments.comments.first(where: { $0.replyCount > 0 }) else {
                continue
            }
            let p1 = try await EpisodeSocialService.repliesPage(seriesId: entry.series.seriesId, vid: entry.firstVid, commentId: target.id, count: 5)
            XCTAssertFalse(p1.replies.isEmpty, "expected non-empty replies for comment \(target.id) with replyCount=\(target.replyCount)")
            print("PROBE replies: sid=\(entry.series.seriesId) vid=\(entry.firstVid) cid=\(target.id) replyCount=\(target.replyCount) p1=\(p1.replies.count) total=\(String(describing: p1.total)) cursor=\(p1.cursor) hasMore=\(p1.hasMore)")
            if p1.hasMore {
                let p2 = try await EpisodeSocialService.repliesPage(seriesId: entry.series.seriesId, vid: entry.firstVid, commentId: target.id, cursor: p1.cursor, count: 5)
                XCTAssertFalse(p2.replies.isEmpty, "expected page 2 replies")
                XCTAssertNotEqual(p1.replies.first?.id, p2.replies.first?.id, "page 2 should advance past page 1")
                print("PROBE replies p2: count=\(p2.replies.count) cursor=\(p2.cursor) hasMore=\(p2.hasMore) sampleReplyTo='\(p2.replies.first(where: { !$0.replyToAuthor.isEmpty })?.replyToAuthor ?? "")'")
            }
            tested = true
            break
        }
        XCTAssertTrue(tested, "did not find any live comment with replies in the first 5 feed entries")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// `HONGGUO_PROBE=codec HONGGUO_VID=<episode id> swift test --filter CodecProbeTests`: what an
/// episode's play model and the forms of its fallback address offer (encoding and size only).
final class CodecProbeTests: XCTestCase {

    func testCodecFallbackOffers() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["HONGGUO_PROBE"] == "codec", let vid = environment["HONGGUO_VID"], !vid.isEmpty else {
            throw XCTSkip("set HONGGUO_PROBE=codec and HONGGUO_VID")
        }
        for (name, result) in await CodecFallback.compare(vid: vid) {
            switch result {
            case .success(let offer):
                print("PROBE codec \(name): duration=\(Int(offer.duration)) streams=\(offer.streams.map(\.description).joined(separator: " "))")
            case .failure(let error):
                print("PROBE codec \(name): failed \((error as? HongguoError)?.message ?? String(describing: type(of: error)))")
            }
        }
    }

    /// `HONGGUO_PROBE=bvc2sample HONGGUO_BVC2_SAMPLE=1 HONGGUO_VID=<id> swift test --filter CodecProbeTests`:
    /// downloads one ByteVC2 episode at 1080 and 720 into captures/ (ignored by git) with its key
    /// beside it, for measuring software decoding. Prints sizes only.
    func testFetchByteVC2Sample() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["HONGGUO_PROBE"] == "bvc2sample", let vid = environment["HONGGUO_VID"], !vid.isEmpty else {
            throw XCTSkip("set HONGGUO_PROBE=bvc2sample, HONGGUO_BVC2_SAMPLE=1 and HONGGUO_VID")
        }
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("captures")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for side in [1080, 720] {
            let info = try await CodecFallback.sampleSource(vid: vid, shortSide: side)
            var request = URLRequest(url: info.url)
            for (name, value) in info.httpHeaders { request.setValue(value, forHTTPHeaderField: name) }
            let (data, _) = try await URLSession.shared.data(for: request)
            try data.write(to: folder.appendingPathComponent("bvc2-\(side).mp4"))
            let key = (info.contentKey ?? []).map { String(format: "%02x", $0) }.joined()
            try Data(key.utf8).write(to: folder.appendingPathComponent("bvc2-\(side).key"))
            print("PROBE bvc2sample \(side): codec=\(info.codec) bytes=\(data.count) quality=\(info.quality?.shortSide ?? 0) key=\(key.isEmpty ? "none" : "saved")")
        }
    }
}


/// `HONGGUO_PROBE=find HONGGUO_TITLE=<part of a title> HONGGUO_VID=<episode id> swift test --filter FindProbeTests`:
/// which series (by search) holds an episode id, and at which episode number.
final class FindProbeTests: XCTestCase {

    func testFindSeriesOfEpisode() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["HONGGUO_PROBE"] == "find", let title = environment["HONGGUO_TITLE"], let vid = environment["HONGGUO_VID"] else {
            throw XCTSkip("set HONGGUO_PROBE=find, HONGGUO_TITLE and HONGGUO_VID")
        }
        let service = SeriesService()
        let found = try await AppSearchService().search(title).results
        for series in found.prefix(5) {
            let list = try await service.episodes(seriesId: series.seriesId)
            if let episode = list.episodes.first(where: { $0.vid == vid }) {
                print("PROBE find: seriesId=\(series.seriesId) episode=\(episode.index) of \(list.episodes.count)")
                return
            }
        }
        print("PROBE find: not among the first \(min(5, found.count)) results")
    }
}

/// `HONGGUO_PROBE=series swift test --filter SeriesTabProbeTests`: inspects `DiscoveryAccess.sameIPSeries`
/// for multi-season / same-IP series (`scene=10&from=single_col_same_ip_series`).
final class SeriesTabProbeTests: XCTestCase {

    func testSameIPSeriesPlan() async throws {
        guard ProcessInfo.processInfo.environment["HONGGUO_PROBE"] == "series" else {
            throw XCTSkip("set HONGGUO_PROBE=series")
        }
        let query = ProcessInfo.processInfo.environment["HONGGUO_TITLE"] ?? "直男上恋综气哭前女友"
        let found = try await AppSearchService().search(query).results
        guard let first = found.first else {
            print("PROBE series: no search result for \(query)")
            return
        }
        let result = try await DiscoveryAccess.sameIPSeries(seriesId: first.seriesId)
        print("PROBE series: picked id=\(first.seriesId) tab=\(result.tabTitle) currentSeason=\(result.currentSeasonIndex) items=\(result.items.count) novel=\(result.novel?.bookName ?? "-")")
        for item in result.items {
            print("  season=\(item.seasonIndex) sid=\(item.seriesId) subId=\(item.subscribeItemId) badge='\(item.badgeText)' title='\(item.title)' sub='\(item.subtitle)' disable=\(item.disablePlay)")
        }
    }

    func testEpisodeSocialFallbackProbe() async throws {
        guard ProcessInfo.processInfo.environment["HONGGUO_PROBE"] == "social" else {
            throw XCTSkip("set HONGGUO_PROBE=social")
        }
        // Pick episode 11 of 收租精神小妹！(7675312158082616345) where web player is 302 locked!
        let sid = ProcessInfo.processInfo.environment["HONGGUO_SID"] ?? "7675312158082616345"
        let list = try await SeriesService().episodes(seriesId: sid)
        let ep11 = list.episodes.first(where: { $0.index == 11 }) ?? list.episodes.first!
        print("PROBE social: sid=\(sid) ep=\(ep11.index) vid=\(ep11.vid)")
        let social = try await EpisodeSocialService.load(seriesId: sid, vid: ep11.vid)
        print("PROBE social loaded: likes=\(social.episodeLikes as Any) fav=\(social.favoriteCount as Any) cmts=\(social.commentTotal as Any) list=\(social.comments.count) hasMore=\(social.hasMoreComments) firstAuthor=\(social.comments.first?.author ?? "-")")
        XCTAssertNotNil(social.episodeLikes)
        XCTAssertNotNil(social.favoriteCount)
        XCTAssertFalse(social.comments.isEmpty)
    }

    func testAppFirstMigrationProbe() async throws {
        guard ProcessInfo.processInfo.environment["HONGGUO_PROBE"] == "catalog" else {
            throw XCTSkip("set HONGGUO_PROBE=catalog")
        }
        // 1. Episodes and synopsis from the App detail service.
        let eps = try await SeriesService().episodes(seriesId: "7675312158082616345")
        let intro = try await SeriesService().publicDetails(seriesId: "7675312158082616345").description
        print("PROBE episodes: count=\(eps.episodes.count) source=\(eps.source) title=\(eps.title) introLen=\(intro.count)")
        XCTAssertGreaterThan(eps.episodes.count, 50)
        XCTAssertEqual(eps.source, .api)
        XCTAssertFalse(intro.isEmpty)

        // 2. Reviews on a series whose website page was unavailable.
        let rev = try await EpisodeSocialService.reviews(seriesId: "7692377412511730713")
        print("PROBE reviews(S3): heat='\(rev.heatText)' fav=\(rev.favoriteCount as Any) record='\(rev.recordNumber)' rating=\(rev.rating as Any)")
        XCTAssertFalse(rev.heatText.isEmpty)
        XCTAssertNotNil(rev.favoriteCount)

        // 3. Search (the App search, HEIC covers kept)
        let searchResults = try await AppSearchService().search("收租精神小妹").results
        let withCovers = searchResults.filter { !$0.cover.isEmpty }.count
        print("PROBE search: count=\(searchResults.count) withCovers=\(withCovers) first=\(searchResults.first?.title ?? "-") cover=\(searchResults.first?.cover.prefix(60) ?? "-")")
        XCTAssertFalse(searchResults.isEmpty)
        XCTAssertEqual(withCovers, searchResults.count)

        // 4. Ranking category tab IDs check
        let rankRoot = try await DiscoveryAccess.ranking(selectedItem: "all", subSelectedItem: "ranklist_hot_sc")
        print("PROBE rankTabs: \(rankRoot.categories.map { "\($0.id):\($0.title)" })")

        // 5. Catalog browse (App landpage first) for 真人剧 / 漫剧 / AI剧 + theme filter + rankings
        for kind in CatalogKind.categories {
            let res = try await DiscoveryAccess.catalog(kind: kind, genre: nil, page: 1, limit: 12)
            print("PROBE cat \(kind.rawValue): items=\(res.items.count) genres=\(res.genres.count) first=\(res.items.first?.title ?? "-") heat=\(res.items.first?.heat ?? "-") tags=\(res.items.first?.tags ?? [])")
            XCTAssertFalse(res.items.isEmpty, "empty items for \(kind.rawValue)")
            if let pickedGenre = res.genres.first(where: { $0.label == "爱情" || $0.label == "奇幻" }) ?? res.genres.first {
                let filtered = try await DiscoveryAccess.catalog(kind: kind, genre: pickedGenre.slug, page: 1, limit: 8)
                print("  filtered \(pickedGenre.slug)(\(pickedGenre.label)): items=\(filtered.items.count) first=\(filtered.items.first?.title ?? "-")")
                XCTAssertFalse(filtered.items.isEmpty, "empty filtered for \(kind.rawValue)/\(pickedGenre.slug)")
            }
        }
        for kind in CatalogKind.rankings {
            let res = try await DiscoveryAccess.catalog(kind: kind, genre: nil, page: 1)
            print("PROBE rank \(kind.rawValue): items=\(res.items.count) first=\(res.items.first?.title ?? "-")")
            XCTAssertFalse(res.items.isEmpty, "empty rank for \(kind.rawValue)")
        }
    }
}
