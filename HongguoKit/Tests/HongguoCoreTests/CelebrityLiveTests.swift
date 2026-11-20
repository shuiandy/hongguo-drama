// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HongguoCore

/// `HONGGUO_LIVE=1 swift test --filter CelebrityLiveTests` (optional `HONGGUO_PROBE=剧名`, a
/// live-action drama): the cast from the App detail, then `works(of:)` for the first actor as the
/// apps call it. One App search and two App reads. Each step logs to stderr as it starts and ends and
/// gives up after 25 s, so a stalled step names itself. Prints names, titles and counts.
final class CelebrityLiveTests: XCTestCase {
    struct StepTimeout: Error, CustomStringConvertible {
        let name: String
        var description: String { "step \(name) did not finish in 25 s" }
    }

    private static func log(_ line: String) {
        FileHandle.standardError.write(Data("[celebrity] \(line)\n".utf8))
    }

    /// Resumes once: with the work's result, or with a timeout after 25 s even if the work never
    /// returns (a task group would wait for a child that ignores cancellation).
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
                Task {
                    do { once.resume(.success(try await work())) } catch { once.resume(.failure(error)) }
                }
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

    func testActorWorks() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["HONGGUO_LIVE"] == "1", "set HONGGUO_LIVE=1 to run")
        let keyword = env["HONGGUO_PROBE"] ?? "家里家外"
        let found = try await Self.step("search") { try await AppSearchService().search(keyword).results.first?.seriesId }
        guard let sid = found else { throw XCTSkip("App search found nothing") }
        try await Task.sleep(for: .seconds(1))
        let detail = try await Self.step("detail") { try await OfficialSeriesDetail.load(sid) }
        var lines = ["series: \(detail.title) cast=\(detail.cast.count) withEncryptedId=\(detail.cast.filter { !$0.encryptedId.isEmpty }.count) withIntro=\(detail.cast.filter { !$0.intro.isEmpty }.count)"]
        Self.log(lines[0])
        let cast = detail.cast.filter { !$0.encryptedId.isEmpty }
        try XCTSkipIf(cast.isEmpty, "this series has no cast with encrypted ids")
        try await Task.sleep(for: .seconds(1))

        if let first = cast.first {
            do {
                let works = try await Self.step("works(of:)") { try await CelebrityService.works(of: first) }
                lines.append("\(first.name) works(of:): \(works.items.count) total=\(works.total ?? -1) includesThisSeries=\(works.items.contains { $0.seriesId == sid })")
                lines.append("  cards with episodes=\(works.items.filter { $0.episodeCount > 0 }.count) genre=\(works.items.filter { !$0.tags.isEmpty }.count) plays=\(works.items.filter { !$0.heat.isEmpty }.count) https=\(works.items.filter { $0.cover.hasPrefix("https://") }.count)")
                for card in works.items.prefix(3) {
                    lines.append("  \(card.title): \(card.episodeCount) 集 \(card.tags.joined(separator: "/")) \(card.heat)")
                }
            } catch { lines.append("works(of:): \(error)") }
        }
        print("CELEBRITY\n" + lines.joined(separator: "\n"))
    }
}
