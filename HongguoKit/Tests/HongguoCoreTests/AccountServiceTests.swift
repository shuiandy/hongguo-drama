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

        XCTAssertTrue(web.requests.allSatisfy { $0.1["User-Agent"] == "HongguoDrama" })

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

    func testReportNotInterestedBodyMatchesOfficialSchema() {
        let dislike = AccountDataAccess.reportNotInterestedBody(seriesId: "7500000000000000001", recall: false)
        XCTAssertEqual(dislike["report_type"] as? Int, 4)
        let dislikeData = dislike["book_feed_dislike_data"] as? [String: Any]
        XCTAssertEqual(dislikeData?["book_id"] as? String, "7500000000000000001")
        XCTAssertEqual(dislikeData?["group_id"] as? String, "7500000000000000001")
        XCTAssertEqual(dislikeData?["op_type"] as? Int, 0)
        XCTAssertEqual(dislikeData?["reason_id"] as? Int, 0)
        XCTAssertEqual(dislikeData?["target_id"] as? Int, 0)

        let recall = AccountDataAccess.reportNotInterestedBody(seriesId: "7500000000000000001", recall: true)
        XCTAssertEqual(recall["report_type"] as? Int, 4)
        let recallData = recall["book_feed_dislike_data"] as? [String: Any]
        XCTAssertEqual(recallData?["book_id"] as? String, "7500000000000000001")
        XCTAssertEqual(recallData?["op_type"] as? Int, 1)
    }

    func testTransientReadRetryRecoversOnceAndSkipsHardErrors() async throws {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func next() -> Int { lock.withLock { value += 1; return value } }
            var count: Int { lock.withLock { value } }
        }

        let flaky = Counter()
        let recovered = try await TransientReadRetry.run(delayNanoseconds: 1_000_000) {
            if flaky.next() == 1 {
                throw HongguoError(.network, "connection lost")
            }
            return "ok"
        }
        XCTAssertEqual(recovered, "ok")
        XCTAssertEqual(flaky.count, 2)

        let nonRetryable = Counter()
        do {
            _ = try await TransientReadRetry.run(delayNanoseconds: 1_000_000) { () async throws -> String in
                _ = nonRetryable.next()
                throw AppSourceError(.http, "HTTP 403", status: 403)
            }
            XCTFail("expected 403 to throw without retry")
        } catch let error as AppSourceError {
            XCTAssertEqual(error.status, 403)
        }
        XCTAssertEqual(nonRetryable.count, 1)

        let expiredDeadline = Counter()
        do {
            _ = try await TransientReadRetry.run(deadline: Date().addingTimeInterval(0.1), delayNanoseconds: 1_000_000) { () async throws -> String in
                _ = expiredDeadline.next()
                throw AppSourceError(.timeout, "timed out")
            }
            XCTFail("expected expired deadline to skip retry")
        } catch let error as AppSourceError {
            XCTAssertEqual(error.code, .timeout)
        }
        XCTAssertEqual(expiredDeadline.count, 1)
    }

    func testTTLCacheCoalescesConcurrentLoadsAndSurvivesSingleWaiterCancel() async throws {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func increment() -> Int { lock.withLock { value += 1; return value } }
            var count: Int { lock.withLock { value } }
        }

        let cache = TTLCache<String>(limit: 8)
        let calls = Counter()

        async let first = cache.load("k1", ttl: 60) {
            let n = calls.increment()
            try await Task.sleep(nanoseconds: 50_000_000)
            return "val-\(n)"
        }
        async let second = cache.load("k1", ttl: 60) {
            let n = calls.increment()
            try await Task.sleep(nanoseconds: 50_000_000)
            return "val-\(n)"
        }
        let (a, b) = try await (first, second)
        XCTAssertEqual(a, "val-1")
        XCTAssertEqual(b, "val-1")
        XCTAssertEqual(calls.count, 1, "concurrent callers must share one in-flight request")

        let cancelCalls = Counter()
        let waiterA = Task {
            try await cache.load("k2", ttl: 60) {
                let n = cancelCalls.increment()
                try await Task.sleep(nanoseconds: 80_000_000)
                return "survived-\(n)"
            }
        }
        let waiterB = Task {
            try await cache.load("k2", ttl: 60) {
                let n = cancelCalls.increment()
                try await Task.sleep(nanoseconds: 80_000_000)
                return "survived-\(n)"
            }
        }
        try await Task.sleep(nanoseconds: 15_000_000)
        waiterA.cancel()
        let resultB = try await waiterB.value
        XCTAssertEqual(resultB, "survived-1")
        XCTAssertEqual(cancelCalls.count, 1)
    }

    func testSMSLoginMixHexNormalizeAndFullFlow() async throws {
        XCTAssertEqual(AccountService.mixHex("24"), "3731")
        XCTAssertEqual(AccountService.mixHex("0"), "35")
        XCTAssertEqual(try AccountService.normalizeMobile("138 0013-8000"), "+8613800138000")
        XCTAssertEqual(try AccountService.normalizeMobile("+86 13800138000"), "+8613800138000")
        XCTAssertEqual(try AccountService.normalizeMobile("415-555-0199", countryCode: "+1"), "+14155550199")
        XCTAssertThrowsError(try AccountService.normalizeMobile("12345"))
        XCTAssertThrowsError(try AccountService.normalizeMobile("23800138000", countryCode: "+86"))

        final class PassportRecorder: @unchecked Sendable {
            let lock = NSLock()
            var calls: [(URL, String, [String: String], String)] = []
            var sendReturnsCaptcha = false
            var omitSetCookie = false
            func record(_ url: URL, _ method: String, _ headers: [String: String], _ body: Data?) {
                lock.withLock { calls.append((url, method, headers, body.map { String(decoding: $0, as: UTF8.self) } ?? "")) }
            }
        }

        let recorder = PassportRecorder()
        let store = MemoryCredentialStore()
        let fakePng = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a] + Array(repeating: UInt8(0x41), count: 24)).base64EncodedString()
        let account = AccountService(
            store: store,
            webRequest: { url, _ in
                // Simulate web passport rejecting an App-issued SMS session so passport fallback is exercised.
                return self.response(url, json: #"{"message":"error","data":{"description":"会话过期"}}"#)
            },
            passportRequest: { url, method, headers, body in
                recorder.record(url, method, headers, body)
                switch url.path(percentEncoded: false) {
                case "/passport/mobile/send_code/":
                    if recorder.sendReturnsCaptcha {
                        return self.response(url, json: #"{"message":"error","data":{"description":"请输入图形验证码","captcha":"\#(fakePng)"}}"#,
                                             headers: ["Set-Cookie": "passport_csrf_token=csrf1; Path=/; Domain=snssdk.com"])
                    }
                    return self.response(url, json: #"{"message":"success","data":{"retry_time":60,"mobile_ticket":"tok1"}}"#,
                                         headers: ["Set-Cookie": "passport_csrf_token=csrf1; Path=/; Domain=snssdk.com"])
                case "/passport/mobile/sms_login/":
                    let setCookie = recorder.omitSetCookie
                        ? "passport_csrf_token=csrf1; Path=/; Domain=snssdk.com"
                        : "sessionid=sms_sess; Path=/; Domain=snssdk.com, sid_tt=sms_sid; Path=/; Domain=snssdk.com"
                    return self.response(url, json: #"{"message":"success","data":{"user_id_str":"7654321","screen_name":"手机用户","session_key":"fallback_sess"}}"#,
                                         headers: ["Set-Cookie": setCookie])
                case "/passport/account/info/v2/":
                    return self.response(url, json: #"{"message":"success","data":{"user_id_str":"7654321","name":"手机用户"}}"#)
                default:
                    return self.response(url, status: 404)
                }
            },
            accountRequest: { _, _ in .null },
            identity: {
                PlaybackIdentity(deviceId: "1234567890123456789", iid: "2234567890123456789", cdid: "01234567-89ab-cdef-0123-456789abcdef")
            }
        )

        // 1. Captcha response surfaced cleanly
        recorder.sendReturnsCaptcha = true
        let captchaStatus = try await account.sendSMSCode(phone: "13800138000")
        guard case .captchaRequired(let image, let msg) = captchaStatus else {
            return XCTFail("expected captchaRequired")
        }
        XCTAssertFalse(image.isEmpty)
        XCTAssertEqual(msg, "请输入图形验证码")

        // 2. Send SMS code with captcha
        recorder.sendReturnsCaptcha = false
        let sent = try await account.sendSMSCode(phone: "13800138000", captcha: "ab12")
        XCTAssertEqual(sent, .sent(retryTime: 60))

        // 3. Login with SMS code forwards CSRF token and saves session
        let loginResult = try await account.loginWithSMSCode(phone: "13800138000", code: "123456")
        guard case .signedIn(let profile, let warning) = loginResult else {
            return XCTFail("expected signedIn")
        }
        XCTAssertEqual(profile, AccountProfile(id: "7654321", nickname: "手机用户"))
        XCTAssertEqual(warning, "")
        XCTAssertTrue(store.current?.cookie.contains("sessionid=sms_sess") == true)

        let loginCall = recorder.calls.first { $0.0.path(percentEncoded: false) == "/passport/mobile/sms_login/" }!
        XCTAssertEqual(loginCall.1, "POST")
        XCTAssertEqual(loginCall.2["x-tt-passport-csrf-token"], "csrf1")
        XCTAssertTrue(loginCall.3.contains("mix_mode=1"))
        XCTAssertTrue(loginCall.3.contains("mobile=\(AccountService.mixHex("+8613800138000"))"))
        XCTAssertTrue(loginCall.3.contains("code=\(AccountService.mixHex("123456"))"))

        // 4. Revalidate falls back to security.snssdk.com when web passport rejects an App session
        let restored = AccountService(
            store: store,
            webRequest: { url, _ in self.response(url, json: #"{"message":"error","data":{"description":"会话过期"}}"#) },
            passportRequest: { url, _, headers, _ in
                XCTAssertEqual(url.path(percentEncoded: false), "/passport/account/info/v2/")
                XCTAssertTrue((headers["Cookie"] ?? "").contains("sessionid=sms_sess"))
                return self.response(url, json: #"{"message":"success","data":{"user_id_str":"7654321","name":"手机用户"}}"#)
            },
            accountRequest: { _, _ in .null },
            identity: {
                PlaybackIdentity(deviceId: "1234567890123456789", iid: "2234567890123456789", cdid: "01234567-89ab-cdef-0123-456789abcdef")
            }
        )
        let status = await restored.status()
        XCTAssertEqual(status.profile?.id, "7654321")
        // Give background revalidate a moment to verify via passport fallback without clearing store.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNotNil(store.current, "passport fallback must keep App-issued SMS session alive")

        // 5. Fallback to data.session_key when Set-Cookie omits sessionid
        recorder.omitSetCookie = true
        _ = await account.logout()
        let fallbackResult = try await account.loginWithSMSCode(phone: "13800138000", code: "654321")
        guard case .signedIn = fallbackResult else { return XCTFail("expected session_key fallback sign-in") }
        XCTAssertTrue(store.current?.cookie.contains("sessionid=fallback_sess") == true)
    }
}
