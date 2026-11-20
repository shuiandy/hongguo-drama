// SPDX-License-Identifier: GPL-3.0-only
// A resolved source written to and read from bytes, so the next launch can start the clip it
// lands on without asking for the source again. The bytes hold a signed address and a content
// key: they belong in the app's own cache folder and never in a log.
import Foundation

public enum PlayInfoArchive {
    public static func encode(_ info: PlayInfo) -> Data? {
        try? JSONSerialization.data(withJSONObject: object(info))
    }

    public static func decode(_ data: Data) -> PlayInfo? {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return info(raw)
    }

    private static func object(_ info: PlayInfo) -> [String: Any] {
        var out: [String: Any] = [
            "url": info.url.absoluteString, "codec": info.codec, "source": info.source.rawValue,
            "vid": info.vid, "userAgent": info.userAgent,
            "variants": info.variants.map(object),
        ]
        let backups = PlayBackupURLs.shared.backups(for: info.url)
        if !backups.isEmpty { out["backupURLs"] = backups.map(\.absoluteString) }
        if let value = info.spadeA { out["spadeA"] = value }
        if let value = info.referer { out["referer"] = value }
        if let value = info.contentKey { out["contentKey"] = Data(value).base64EncodedString() }
        if let value = info.quality { out["quality"] = value.shortSide }
        return out
    }

    private static func info(_ raw: [String: Any]) -> PlayInfo? {
        guard let address = raw["url"] as? String, let url = URL(string: address), url.scheme == "https",
              let codec = raw["codec"] as? String, let source = (raw["source"] as? String).flatMap(PlaySource.init(rawValue:)),
              let vid = raw["vid"] as? String, let userAgent = raw["userAgent"] as? String else { return nil }
        if let rawBackups = raw["backupURLs"] as? [String], !rawBackups.isEmpty {
            let backups = rawBackups.compactMap(URL.init(string:)).filter { $0.scheme == "https" }
            if !backups.isEmpty { PlayBackupURLs.shared.register(primary: url, backups: backups) }
        }
        var out = PlayInfo(url: url, spadeA: raw["spadeA"] as? String, codec: codec, source: source, vid: vid,
                           userAgent: userAgent, referer: raw["referer"] as? String)
        if let key = raw["contentKey"] as? String, let bytes = Data(base64Encoded: key) { out.contentKey = [UInt8](bytes) }
        if let side = raw["quality"] as? Int { out.quality = QualityOption(shortSide: side) }
        out.variants = ((raw["variants"] as? [[String: Any]]) ?? []).compactMap(info)
        return out
    }
}
