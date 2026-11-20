// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HongguoCore

/// `HONGGUO_LIVE=1 swift test --filter CelebrityLiveTests` (optional `HONGGUO_PROBE=剧名`, a
/// live-action drama): the cast from the App detail, then the actor works read once the way the
/// official actor panel asks (every actor, count 10) and twice for the first actor (offset 0 and 20,
/// count 20) to see paging. One App search and four App reads. Each step logs to stderr as it starts
/// and ends and gives up after 25 s, so a stalled step names itself. Prints names, titles and counts.
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

        do {
            let ids = cast.map(\.encryptedId)
            let reply = try await Self.step("panel read") { try await CelebrityService.request(encryptedIds: ids, offset: 0, count: 10) }
            Self.log("panel read code=\(Int(reply["code"].number ?? -1)) msg=\((reply["message"].string ?? "").prefix(40))")
            let all = try CelebrityService.parse(reply)
            lines.append("panel read: \(all.count) of \(cast.count) actors answered")
            for member in cast.prefix(6) {
                let works = all[member.encryptedId]
                lines.append("  \(member.name): total=\(works?.total ?? -1) hasMore=\(works?.hasMore ?? false) page=\(works?.items.count ?? -1) " +
                             (works?.items.prefix(3).map(\.title).joined(separator: " / ") ?? "-"))
            }
        } catch { lines.append("panel read: \(error)") }
        try await Task.sleep(for: .seconds(1))

        if let first = cast.first {
            do {
                let page1 = try await Self.step("actor page 1") { try await CelebrityService.works(of: first, offset: 0, count: 20) }
                lines.append("\(first.name) page 1: \(page1.items.count) total=\(page1.total ?? -1) hasMore=\(page1.hasMore) includesThisSeries=\(page1.items.contains { $0.seriesId == sid })")
                if let card = page1.items.first {
                    lines.append("  first card: label=\(card.episodeLabel) count=\(card.episodeCount) heat=\(card.heat) https=\(card.cover.hasPrefix("https://"))")
                }
                if page1.hasMore {
                    try await Task.sleep(for: .seconds(1))
                    let offset = page1.nextOffset
                    let page2 = try await Self.step("actor page 2") { try await CelebrityService.works(of: first, offset: offset, count: 20) }
                    let overlap = Set(page2.items.map(\.seriesId)).intersection(page1.items.map(\.seriesId)).count
                    lines.append("\(first.name) page 2: \(page2.items.count) overlap=\(overlap) hasMore=\(page2.hasMore)")
                }
            } catch { lines.append("single actor: \(error)") }
        }
        print("CELEBRITY\n" + lines.joined(separator: "\n"))
    }
}
