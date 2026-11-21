// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HongguoCore

final class MemoryCredentialStore: AccountCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: AccountCredentials?
    init(_ value: AccountCredentials? = nil) { self.value = value }
    func load() throws -> AccountCredentials? { lock.lock(); defer { lock.unlock() }; return value }
    func save(_ value: AccountCredentials) throws { lock.lock(); self.value = value; lock.unlock() }
    func clear() throws { lock.lock(); value = nil; lock.unlock() }
    var current: AccountCredentials? { lock.lock(); defer { lock.unlock() }; return value }
}

final class AccountServiceTests: XCTestCase {
    final class Web: @unchecked Sendable {
        let lock = NSLock()
        var requests: [(URL, [String: String])] = []
        var pollStatus = "1"
        var profileOK = true
        func record(_ url: URL, _ headers: [String: String]) { lock.lock(); requests.append((url, headers)); lock.unlock() }
    }

    func response(_ url: URL, status: Int = 200, json: String = "", headers: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(data: Data(json.utf8), status: status, headers: headers, url: url)
    }

    func service(_ web: Web, store: MemoryCredentialStore, history: @escaping @Sendable (String, [(String, String)]) async throws -> JSONValue = { _, _ in .null }) -> AccountService {
        let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0]).base64EncodedString()
        return AccountService(store: store, webRequest: { url, headers in
            web.record(url, headers)
            switch url.path(percentEncoded: false) {
            case "/passport/web/get_qrcode/":
                return self.response(url, json: #"{"message":"success","data":{"token":"tok","qrcode":"data:image/png;base64,\#(png)","expire_time":120}}"#,
                                     headers: ["Set-Cookie": "passport_csrf_token=abc; Path=/"])
            case "/passport/web/check_qrconnect/":
                if web.pollStatus == "3" {
                    return self.response(url, json: #"{"message":"success","data":{"status":"3","redirect_url":"https://hongguoduanju.com/passport/sso/finish?x=1"}}"#)
                }
                return self.response(url, json: #"{"message":"success","data":{"status":"\#(web.pollStatus)"}}"#)
            case "/passport/sso/finish":
                return self.response(url, status: 302, headers: ["Location": "/", "Set-Cookie": "sessionid=s3cret; Path=/; HttpOnly, sid_tt=t; Path=/"])
            case "/":
                return self.response(url, json: "<html></html>")
            case "/passport/account/info/v2/":
                if !web.profileOK { return self.response(url, json: #"{"message":"error","data":{"description":"会话过期"}}"#) }
                return self.response(url, json: #"{"message":"success","data":{"user_id_str":"1234567","name":"<b>小红</b>"}}"#)
            default:
                return self.response(url, status: 404)
            }
        }, accountRequest: history, identity: {
            PlaybackIdentity(deviceId: "1234567890123456789", iid: "2234567890123456789", cdid: "01234567-89ab-cdef-0123-456789abcdef")
        })
    }

    func testQRLoginHistoryAndLogout() async throws {
        let web = Web(), store = MemoryCredentialStore()
        let account = service(web, store: store, history: { url, headers in
            XCTAssertTrue(url.hasPrefix("https://api5-normal-sinfonlinea.fqnovel.com/reading/bookapi/read_history/list/v1/?book_type=2&"))
            XCTAssertEqual(headers.first { $0.0 == "Cookie" }?.1, "passport_csrf_token=abc; sessionid=s3cret; sid_tt=t")
            return try JSONValue.parse("""
            {"code":0,"message":"success","data":{"data_list":[
              {"book_id_str":"7200000000000000001","vid":7300000000000000003,"vid_index":3,"series_title":"霸总","current_play_position":42500,"duration":90000,"read_timestamp_ms":1763430000000,"episode_cnt":60,"cover":"//p3.example.com/a.jpg"},
              {"book_id_str":"7200000000000000001","vid":"7300000000000000001","vid_index":1,"read_timestamp_ms":1763420000000},
              {"book_id_str":"7200000000000000002","vid":"7300000000000000009","is_delete":true},
              {"book_id":7200000000000000004,"item_id":"7300000000000000010","last_watch_time":1763440000}
            ]}}
            """)
        })
        let qr = try await account.startLogin()
        XCTAssertEqual(qr.expiresIn, 120)
        XCTAssertEqual(qr.image.prefix(4), Data([0x89, 0x50, 0x4e, 0x47]))
        let pending = try await account.pollLogin(qr.loginId)
        XCTAssertEqual(pending, .pending)
        web.pollStatus = "3"
        let done = try await account.pollLogin(qr.loginId)
        XCTAssertEqual(done, .signedIn(AccountProfile(id: "1234567", nickname: "小红"), storageWarning: ""))
        XCTAssertEqual(store.current?.cookie, "passport_csrf_token=abc; sessionid=s3cret; sid_tt=t")
        let poll = web.requests.first { $0.0.path(percentEncoded: false) == "/passport/web/check_qrconnect/" }!
        XCTAssertTrue(poll.0.query!.contains("token=tok"))
        XCTAssertTrue(poll.0.query!.contains("aid=513755"))

        let history = try await account.history()
        XCTAssertEqual(history.map(\.seriesId), ["7200000000000000004", "7200000000000000001"])
        let first = history[1]
        XCTAssertEqual(first.episodeId, "7300000000000000003", "19-digit ids keep every digit")
        XCTAssertEqual(first.position, 42.5)
        XCTAssertEqual(first.cover, "https://p3.example.com/a.jpg")
        XCTAssertEqual(history[0].seriesTitle, "剧集 7200000000000000004")
        XCTAssertEqual(history[0].updatedAt, Date(timeIntervalSince1970: 1_763_440_000))

        let warning = await account.logout()
        XCTAssertEqual(warning, "")
        XCTAssertNil(store.current)
        let status = await account.status()
        XCTAssertNil(status.profile)
        let empty = try await account.history()
        XCTAssertEqual(empty, [])
    }

    func testRestoreShowsSavedProfileAndDropsRejectedCookie() async throws {
        let web = Web()
        web.profileOK = false
        let store = MemoryCredentialStore(AccountCredentials(cookie: "sessionid=old", profile: AccountProfile(id: "1234567", nickname: "小红")))
        let account = service(web, store: store)
        let expired = expectation(forNotification: AccountService.sessionExpiredNotification, object: nil)
        let status = await account.status()
        XCTAssertEqual(status.profile?.id, "1234567", "the saved profile shows at once")
        await fulfillment(of: [expired], timeout: 2)
        XCTAssertNil(store.current, "an expired cookie is removed after the background check")
        let after = await account.status()
        XCTAssertNil(after.profile, "the apps see the signed-out state once told")
    }

    func testWebViewLoginNeedsSessionCookie() async throws {
        let web = Web(), store = MemoryCredentialStore()
        let account = service(web, store: store)
        do { _ = try await account.completeWebLogin(cookie: "foo=bar"); XCTFail("expected an error") } catch {}
        let result = try await account.completeWebLogin(cookie: "sessionid_ss=abc; foo=bar")
        guard case .signedIn(let profile, _) = result else { return XCTFail("not signed in") }
        XCTAssertEqual(profile.nickname, "小红")
    }

    func testParsersAndSafeMessage() throws {
        XCTAssertThrowsError(try AccountService.parseProfile(try JSONValue.parse(#"{"message":"success","data":{"user_id":"0"}}"#)))
        XCTAssertEqual(AccountService.cleanCover("https://p9-reading-sign.fqnovelpic.com/novel-pic/x~tplv-abc.heic?sig=1"),
                       "https://p3-novel.byteimg.com/novel-pic/x~tplv-shrink:320:0.webp")
        XCTAssertEqual(AccountService.safeMessage(HongguoError(.upstream, "失败 sessionid=abc; https://a.example.com/x")),
                       "失败 sessionid=[已隐藏]; [地址]")
        let qr = try AccountService.parseQR(try JSONValue.parse(#"{"message":"success","data":{"token":"t","qrcode":"iVBORw0KGgoAAA==","expire_time":1800000100}}"#),
                                            now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(qr.expiresIn, 100)
    }

    func testAccountReadRetryOnlyOnTransientNetworkOrTimeout() {
        XCTAssertTrue(AccountDataAccess.shouldRetryTransientRead(AppSourceError(.network, "网络连接失败")))
        XCTAssertTrue(AccountDataAccess.shouldRetryTransientRead(AppSourceError(.timeout, "请求超时")))
        XCTAssertFalse(AccountDataAccess.shouldRetryTransientRead(AppSourceError(.cancelled, "已取消")))
        XCTAssertFalse(AccountDataAccess.shouldRetryTransientRead(AppSourceError(.http, "HTTP 401", status: 401)))
        XCTAssertFalse(AccountDataAccess.shouldRetryTransientRead(AppSourceError(.securityBlocked, "blocked")))
        XCTAssertFalse(AccountDataAccess.shouldRetryTransientRead(AppSourceError(.invalidResponse, "bad json")))
    }
}
