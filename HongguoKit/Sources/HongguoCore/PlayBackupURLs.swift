// SPDX-License-Identifier: GPL-3.0-only
// Process-wide bounded lookup mapping a PlayInfo's primary media URL to its server-supplied
// backup CDN URLs (`backup_url` / `backup_url_list`). Keeps backup URLs out of the read-only
// submodule's `PlayInfo` struct while allowing `FastCencOpener` and `StreamingResourceLoader`
// to fail over seamlessly between CDN edges without tearing down AVPlayer.
import Foundation

public final class PlayBackupURLs: @unchecked Sendable {
    public static let shared = PlayBackupURLs()

    private let lock = NSLock()
    private let maxEntries = 512
    private var map: [URL: [URL]] = [:]
    private var order: [URL] = []

    public init() {}

    public func register(primary: URL, backups: [URL]) {
        var unique: [URL] = []
        var seen: Set<URL> = [primary]
        for url in backups where seen.insert(url).inserted {
            unique.append(url)
        }
        lock.withLock {
            if unique.isEmpty {
                map[primary] = nil
                order.removeAll { $0 == primary }
                return
            }
            map[primary] = unique
            order.removeAll { $0 == primary }
            order.append(primary)
            while order.count > maxEntries {
                let evicted = order.removeFirst()
                map[evicted] = nil
            }
        }
    }

    public func backups(for primary: URL) -> [URL] {
        lock.withLock { map[primary] ?? [] }
    }

    public func allCandidates(startingWith primary: URL) -> [URL] {
        [primary] + backups(for: primary)
    }
}
