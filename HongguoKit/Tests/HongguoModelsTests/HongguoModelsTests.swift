import AppLogic
import XCTest
@testable import HongguoCore
@testable import HongguoModels

// Offline only: accounts are `.offline` or `.preview` (never `.live`, which reads the keychain
// and may make requests), live-mode storage goes to a temporary folder, defaults to a suite.

@MainActor
final class LibraryModelTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("HongguoModelsTests-\(UUID().uuidString)")
    }

    private func suite() -> UserDefaults {
        let name = "HongguoModelsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func liveModel(base: URL, defaults: UserDefaults, account: AccountModel? = nil) -> LibraryModel {
        LibraryModel(offline: false, account: account ?? AccountModel(mode: .offline), backend: FixtureBackend(),
                     defaults: defaults, base: base)
    }

    func testEpisodePositionsPersistUnderTheBaseFolder() throws {
        let base = temporaryDirectory()
        let defaults = suite()
        let model = liveModel(base: base, defaults: defaults)
        model.rememberEpisode(seriesId: "s1", episode: 7, position: 42)
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathComponent("episode-positions.json").path))
        let reopened = liveModel(base: base, defaults: defaults)
        XCTAssertEqual(reopened.episodePositions, model.episodePositions)
        XCTAssertNotEqual(reopened.episodePositions, EpisodePositionBook())
    }

    func testLocalReservationsSignedOut() throws {
        let base = temporaryDirectory()
        let defaults = suite()
        let model = liveModel(base: base, defaults: defaults)
        let before = model.libraryRevision
        model.toggleReservation(seriesId: "r1", title: "预约一", cover: "", releaseText: "周五上线")
        XCTAssertTrue(model.isReserved("r1"))
        XCTAssertEqual(model.reservations().map(\.seriesId), ["r1"])
        XCTAssertGreaterThan(model.libraryRevision, before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathComponent("reservations.json").path))
        XCTAssertEqual(liveModel(base: base, defaults: defaults).reservations().first?.releaseText, "周五上线")
        model.toggleReservation(seriesId: "r1", title: "预约一", cover: "")
        XCTAssertFalse(model.isReserved("r1"))
        model.toggleReservation(seriesId: "r2", title: "预约二", cover: "")
        model.removeLocalReservation(seriesId: "r2")
        XCTAssertTrue(liveModel(base: base, defaults: defaults).reservations().isEmpty)
    }

    func testFavoriteAndLikeSignedOutStayOnTheDevice() {
        let model = liveModel(base: temporaryDirectory(), defaults: suite())
        model.toggleFavorite(seriesId: "f1", title: "收藏一", cover: "")
        XCTAssertTrue(model.isFavorite("f1"))
        XCTAssertEqual(model.favorites().map(\.seriesId), ["f1"])
        model.toggleFavorite(seriesId: "f1", title: "收藏一", cover: "")
        XCTAssertFalse(model.isFavorite("f1"))

        model.toggleLike(seriesId: "l1", title: "点赞一", vid: "v1", episodeIndex: 1)
        XCTAssertTrue(model.isLiked(seriesId: "l1", vid: "v1", episodeIndex: 1))
        XCTAssertEqual(model.likedSeries().map(\.seriesId), ["l1"])
        model.removeLocalLike(seriesId: "l1", vid: "v1")
        XCTAssertFalse(model.isLiked(seriesId: "l1", vid: "v1", episodeIndex: 1))
    }

    func testNotInterestedAndFeedExposures() {
        let defaults = suite()
        let model = liveModel(base: temporaryDirectory(), defaults: defaults)
        model.recordFeedImpression("a")
        model.recordFeedImpression("b")
        model.recordFeedImpression("b")
        model.markNotInterested(seriesId: "x")
        XCTAssertTrue(model.isDisliked("x"))
        XCTAssertNotNil(defaults.string(forKey: "dislikedSeriesIds"))
        XCTAssertNotNil(defaults.string(forKey: "recentFeedSeriesIds"))
        // Disliked first, then the recent exposures, each once.
        XCTAssertEqual(model.feedForceFilterIds.first, "x")
        XCTAssertEqual(Set(model.feedForceFilterIds), ["x", "a", "b"])
        XCTAssertEqual(model.feedForceFilterIds.count, 3)
        // Read back by a new model from the same defaults.
        let reopened = liveModel(base: temporaryDirectory(), defaults: defaults)
        XCTAssertTrue(reopened.isDisliked("x"))
        XCTAssertEqual(reopened.recentFeedImprIds, model.recentFeedImprIds)
        model.undoNotInterested(seriesId: "x")
        XCTAssertFalse(model.isDisliked("x"))
    }

    func testSettingsAreSavedToTheStore() {
        let base = temporaryDirectory()
        let model = liveModel(base: base, defaults: suite())
        var settings = model.settings
        settings.playbackRate = 1.25
        model.settings = settings
        XCTAssertEqual(model.store.settings.playbackRate, 1.25)
        XCTAssertEqual(liveModel(base: base, defaults: suite()).settings.playbackRate, 1.25)
    }

    /// Sample runs are seeded with four history rows and three favourites in a temporary folder,
    /// and never start the live sequence.
    func testOfflineSeedsSamplesAndStaysLocal() {
        let account = AccountModel(mode: .offline)
        let model = LibraryModel(offline: true, account: account, backend: FixtureBackend(), defaults: suite())
        XCTAssertEqual(model.history().count, 4)
        XCTAssertEqual(model.favorites().count, 3)
        model.startLive { true }
        XCTAssertNil(account.onHistoryRows)
        XCTAssertNil(account.onSessionChanged)
    }

    /// Signed in (the preview account), the account's lists answer; no write is sent because the
    /// account is not live.
    func testPreviewAccountAnswersFromItsLists() async {
        let model = liveModel(base: temporaryDirectory(), defaults: suite(), account: AccountModel(mode: .preview))
        XCTAssertTrue(model.isFavorite("preview-shelf-1"))
        XCTAssertTrue(model.isReserved("preview-reserve-1"))
        await model.syncAccount(force: true)
        XCTAssertTrue(model.isFavorite("preview-shelf-1"))
    }
}

@MainActor
final class LoginModelTests: XCTestCase {
    private final class FakeClient: QRLoginClient {
        var answers: [Bool?] = []
        var started = 0
        var cancelled: [String?] = []
        var failStart = false

        func startQR() async throws -> AccountLoginQR {
            started += 1
            if failStart { throw HongguoError(.unavailable, "二维码服务不可用") }
            return AccountLoginQR(loginId: "code-\(started)", image: Data(), expiresIn: 180)
        }

        func pollQR(_ loginId: String) async throws -> Bool? {
            answers.isEmpty ? nil : answers.removeFirst()
        }

        func cancelQR(_ loginId: String?) async { cancelled.append(loginId) }
    }

    func testPollsUntilSignedInThenCallsBack() async {
        let client = FakeClient()
        client.answers = [nil, nil, true]
        let model = LoginModel(client: client, pollInterval: .milliseconds(1))
        var signedIn = false
        await model.run { signedIn = true }
        XCTAssertTrue(signedIn)
        XCTAssertEqual(model.phase, .done)
        XCTAssertEqual(client.started, 1)
        XCTAssertEqual(model.qr?.loginId, "code-1")
    }

    func testExpiredCodeStartsANewRound() async {
        let client = FakeClient()
        client.answers = [false]
        let model = LoginModel(client: client, pollInterval: .milliseconds(1))
        await model.run {}
        XCTAssertEqual(model.phase, .loading)
        XCTAssertEqual(model.round, 1)
    }

    func testFailureShowsTheMessage() async {
        let client = FakeClient()
        client.failStart = true
        let model = LoginModel(client: client, pollInterval: .milliseconds(1))
        await model.run {}
        XCTAssertEqual(model.phase, .failed("二维码服务不可用"))
    }

    /// Coming back (the task restarts) keeps polling the code already shown.
    func testRestartKeepsTheWaitingCode() async {
        let client = FakeClient()
        let model = LoginModel(client: client, pollInterval: .milliseconds(5))
        let first = Task { await model.run {} }
        while model.phase != .waiting { await Task.yield() }
        first.cancel()
        await first.value
        client.answers = [true]
        await model.run {}
        XCTAssertEqual(client.started, 1)
        XCTAssertEqual(model.phase, .done)
    }

    func testAbandonGivesUpTheCodeUnlessDone() async {
        let client = FakeClient()
        let model = LoginModel(client: client, pollInterval: .milliseconds(5))
        let task = Task { await model.run {} }
        while model.phase != .waiting { await Task.yield() }
        task.cancel()
        await task.value
        model.abandon()
        XCTAssertNil(model.qr)
        XCTAssertEqual(model.phase, .loading)
        for _ in 0..<50 where client.cancelled.isEmpty { await Task.yield() }
        XCTAssertEqual(client.cancelled, ["code-1"])

        client.answers = [true]
        await model.run {}
        model.abandon()
        XCTAssertEqual(model.phase, .done)
        XCTAssertEqual(client.cancelled.count, 1)
    }
}

final class FixtureBackendAndLaunchTests: XCTestCase {
    func testFixtureBackendShapes() async throws {
        let backend = FixtureBackend()
        XCTAssertTrue(backend.isOffline)
        let page = try await backend.catalog(kind: .hotDrama, genre: nil, page: 1)
        XCTAssertEqual(page.items.count, 18)
        XCTAssertEqual(page.totalPages, 2)
        let series = try await backend.series(seriesId: "fixture-3")
        XCTAssertEqual(series.total, FixtureBackend.summary(3).episodeCount)
        XCTAssertEqual(series.episodes.first?.index, 1)
        XCTAssertFalse(LiveBackend().isOffline)
    }

    func testLaunchArgumentsAndAccountMode() {
        let name = "LaunchArgumentsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(LaunchArguments(defaults: defaults, environment: [:]), LaunchArguments())
        XCTAssertEqual(LaunchArguments().accountMode, .live)
        defaults.set(true, forKey: "HongguoOfflineFixtures")
        defaults.set(true, forKey: "HongguoMuted")
        defaults.set("theater", forKey: "HongguoRoute")
        let args = LaunchArguments(defaults: defaults, environment: [:])
        XCTAssertTrue(args.offlineFixtures)
        XCTAssertTrue(args.muted)
        XCTAssertEqual(args.route, "theater")
        XCTAssertEqual(args.accountMode, .offline)
        defaults.set(true, forKey: "HongguoAccountPreview")
        XCTAssertEqual(LaunchArguments(defaults: defaults, environment: [:]).accountMode, .preview)
        XCTAssertTrue(LaunchArguments(defaults: UserDefaults(suiteName: name + "-empty")!,
                                      environment: ["HONGGUO_OFFLINE": "1"]).offlineFixtures)
    }
}
