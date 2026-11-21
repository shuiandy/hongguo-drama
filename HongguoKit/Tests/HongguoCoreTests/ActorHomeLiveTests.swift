// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HongguoCore

/// `HONGGUO_LIVE=1 swift test --filter ActorHomeLiveTests` (optional `HONGGUO_PROBE=剧名`, a
/// live-action drama): the cast from the App detail, then the first actor's home page tabs and the
/// 剧作 lists as the apps read them. One App search and up to four App reads. Each step logs to
/// stderr as it starts and ends and gives up after 25 s. Prints names, titles and counts only.
final class ActorHomeLiveTests: XCTestCase {
    struct StepTimeout: Error, CustomStringConvertible {
        let name: String
        var description: String { "step \(name) did not finish in 25 s" }
    }

    private static func log(_ line: String) {
        FileHandle.standardError.write(Data("[actor] \(line)\n".utf8))
    }

    /// Resumes once: with the work's result, or with a timeout after 25 s even if the work never returns.
    private final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
        func resume(_ result: Result<T, Error>) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(with: result)
        }
    }

    private static func step<T: Sendable>(_ name: String, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let started = Date()
        log("\(name) start")
        do {
            let value: T = try await withCheckedThrowingContinuation { continuation in
                let once = Once(continuation)
                Task { do { once.resume(.success(try await work())) } catch { once.resume(.failure(error)) } }
                Task {
                    try? await Task.sleep(for: .seconds(25))
                    once.resume(.failure(StepTimeout(name: name)))
                }
            }
            log("\(name) done \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            return value
        } catch {
            log("\(name) failed \(Int(Date().timeIntervalSince(started) * 1000)) ms: \(error)")
            throw error
        }
    }

    func testActorHome() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["HONGGUO_LIVE"] == "1", "set HONGGUO_LIVE=1 to run")
        let keyword = env["HONGGUO_PROBE"] ?? "家里家外"
        let found = try await Self.step("search") { try await AppSearchService().search(keyword).results.first?.seriesId }
        guard let sid = found else { throw XCTSkip("App search found nothing") }
        try await Task.sleep(for: .seconds(1))
        let detail = try await Self.step("detail") { try await OfficialSeriesDetail.load(sid) }
        var lines = ["series: \(detail.title) cast=\(detail.cast.count) withAccount=\(detail.cast.filter { !$0.profileUserId.isEmpty }.count)"]
        guard let actor = detail.cast.first(where: { !$0.profileUserId.isEmpty }) else { throw XCTSkip("no cast member with an account") }
        try await Task.sleep(for: .seconds(1))

        let home = try await Self.step("home") { try await ActorHomeService.home(userId: actor.profileUserId) }
        lines.append("\(actor.name) tabs: " + home.tabs.map { tab in
            "\(tab.name)(\(tab.type)) total=\(tab.total ?? -1) subs=[" + tab.subTabs.map { "\($0.name)=\($0.type)/\($0.total ?? -1)" }.joined(separator: " ") + "]"
        }.joined(separator: " | ") + " highlight=\(home.highlight ?? -1)")
        guard let works = home.worksTab else {
            print("ACTOR HOME\n" + lines.joined(separator: "\n"))
            return XCTFail("no 剧作 tab")
        }
        for sub in works.subTabs.prefix(2) {
            try await Task.sleep(for: .seconds(1))
            do {
                let page = try await Self.step("works \(sub.name)") { try await ActorHomeService.works(userId: actor.profileUserId, tab: works.type, subTab: sub.type) }
                let released = page.items.filter { $0.publishedAt == nil }
                lines.append("\(sub.name): items=\(page.items.count) released=\(released.count) upcoming=\(page.items.count - released.count) note=\(page.upcomingNote) hasMore=\(page.hasMore) includesThisSeries=\(page.items.contains { $0.seriesId == sid })")
                lines.append("  with cover=\(page.items.filter { $0.cover.hasPrefix("https://") }.count) heat=\(page.items.filter { !$0.heat.isEmpty }.count) label=\(page.items.filter { !$0.episodeLabel.isEmpty }.count) intro=\(page.items.filter { !$0.description.isEmpty }.count)")
                for card in page.items.prefix(3) { lines.append("  \(card.title): \(card.episodeLabel) \(card.heat)") }
                let hottest = ActorHomeService.hottestFirst(page.items).prefix(3).map(\.heat)
                lines.append("  hottest first: \(hottest.joined(separator: ", "))")
            } catch { lines.append("\(sub.name): \(error)") }
        }
        print("ACTOR HOME\n" + lines.joined(separator: "\n"))
    }
}
