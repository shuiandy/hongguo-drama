import Foundation
import HongguoCore
import Observation

/// What the QR sign-in needs from the account: a code, its state, and cancelling it.
/// `AccountModel` is the real one; tests use a stand-in that never touches the network.
@MainActor
public protocol QRLoginClient: AnyObject {
    func startQR() async throws -> AccountLoginQR
    /// nil while waiting; true once signed in; false when the code expired or was cancelled.
    func pollQR(_ loginId: String) async throws -> Bool?
    func cancelQR(_ loginId: String?) async
}

extension AccountModel: QRLoginClient {}

/// Sign-in with a QR code scanned by the 红果 App on another device: fetch a code, ask every two
/// seconds until it is confirmed, swap in a new one when it expires. Moved from the iOS app's
/// `LoginView`. The page drives it with `.task(id:)` over `round` and whether the app is in
/// front, so leaving and coming back keeps polling the same code instead of fetching a new one.
@MainActor
@Observable
public final class LoginModel {
    public enum Phase: Equatable, Sendable {
        case loading, waiting, expired, done
        case failed(String)

        public var text: String {
            switch self {
            case .loading: return "正在获取二维码…"
            case .waiting: return "等待扫码并在红果 App 里确认"
            case .expired: return "二维码已过期，正在换一个…"
            case .done: return "登录成功"
            case .failed(let message): return message
            }
        }
    }

    public private(set) var qr: AccountLoginQR?
    public private(set) var phase = Phase.loading
    /// Bumped to fetch a new code; part of the page's task id.
    public private(set) var round = 0

    @ObservationIgnored private let client: QRLoginClient
    @ObservationIgnored private let pollInterval: Duration

    /// `pollInterval` is two seconds; tests shorten it.
    public init(client: QRLoginClient, pollInterval: Duration = .seconds(2)) {
        self.client = client
        self.pollInterval = pollInterval
    }

    /// One code: fetch it unless one is still being waited on, then ask every two seconds until it
    /// is confirmed (then `onSignedIn` after a short pause showing 登录成功), expires (a new round
    /// starts a second later) or the task is cancelled.
    public func run(onSignedIn: @MainActor () -> Void) async {
        do {
            var current = qr
            if current == nil || phase != .waiting {
                phase = .loading
                qr = nil
                let next = try await client.startQR()
                current = next
                qr = next
                phase = .waiting
            }
            guard let current else { return }
            while !Task.isCancelled {
                guard let done = try await client.pollQR(current.loginId) else {
                    try await Task.sleep(for: pollInterval)
                    continue
                }
                if done {
                    phase = .done
                    try? await Task.sleep(for: .seconds(0.6))
                    onSignedIn()
                } else {
                    phase = .expired
                    try await Task.sleep(for: .seconds(1))
                    phase = .loading
                    round += 1
                }
                return
            }
        } catch is CancellationError {
        } catch {
            phase = .failed((error as? HongguoError)?.message ?? "二维码暂时取不到")
        }
    }

    /// 换一个二维码.
    public func requestNewCode() {
        phase = .loading
        round += 1
    }

    /// The page went away (or switched to another way of signing in) before the sign-in finished:
    /// the code is given up and the next visit starts with a new one.
    public func abandon() {
        guard phase != .done else { return }
        let id = qr?.loginId
        Task { await client.cancelQR(id) }
        qr = nil
        phase = .loading
    }
}
