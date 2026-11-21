import XCTest
@testable import HongguoCore

/// `AppTransport.withDeadline` must return at its deadline even when the operation is stuck in a
/// call that ignores cancellation (as a system DNS lookup does).
final class DeadlineTests: XCTestCase {
    func testDeadlineReturnsWhileTheOperationIgnoresCancellation() async {
        let transport = AppTransport(http: .shared)
        let started = Date()
        do {
            _ = try await transport.withDeadline(Date().addingTimeInterval(0.3)) { () async throws -> Int in
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 3) { continuation.resume() }
                }
                return 1
            }
            XCTFail("expected a timeout")
        } catch let error as AppSourceError {
            XCTAssertEqual(error.code, .timeout)
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    func testDeadlinePassesResultsAndErrorsThrough() async throws {
        let transport = AppTransport(http: .shared)
        let value = try await transport.withDeadline(Date().addingTimeInterval(5)) { () async throws -> Int in 42 }
        XCTAssertEqual(value, 42)
        do {
            _ = try await transport.withDeadline(Date().addingTimeInterval(5)) { () async throws -> Int in throw HongguoError(.input, "x") }
            XCTFail("expected the operation's error")
        } catch let error as HongguoError {
            XCTAssertEqual(error.kind, .input)
        }
    }

    func testCallerCancellationEndsTheWait() async {
        let transport = AppTransport(http: .shared)
        let task = Task {
            try await transport.withDeadline(Date().addingTimeInterval(10)) { () async throws -> Int in
                try await Task.sleep(for: .seconds(5))
                return 1
            }
        }
        try? await Task.sleep(for: .milliseconds(100))
        let started = Date()
        task.cancel()
        let result = await task.result
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        if case .success = result { XCTFail("expected cancellation") }
    }
}
