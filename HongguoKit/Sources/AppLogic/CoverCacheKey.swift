import CryptoKit
import Foundation

/// Normalizes cover image URLs so signed ByteDance / Tomato CDN URLs that rotate
/// `x-expires` and `x-signature` query parameters still map to the same cache key.
public enum CoverCacheKey {
    private static let immutableCDNHosts = [
        ".fqnovelpic.com",
        ".byteimg.com",
        ".toutiaoimg.com",
        ".pstatp.com",
        ".snssdk.com",
    ]

    private static let ephemeralQueryKeys: Set<String> = [
        "x-signature", "x-expires", "lk3s", "signature", "expires", "sig",
    ]

    /// Returns a stable cache key for `urlString`.
    /// For signed ByteDance / Tomato CDN cover URLs, strips rotating query parameters
    /// and collapses edge subdomains (`p3-` / `p6-` / `p9-`) when the path carries a
    /// content-addressed image hash (e.g. `/novel-pic/<hash>~...`).
    public static func normalizedKey(for urlString: String) -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var components = URLComponents(string: trimmed) else {
            return trimmed
        }
        let host = (components.host ?? "").lowercased()
        guard immutableCDNHosts.contains(where: { host.hasSuffix($0) }) else { return trimmed }

        if let query = components.percentEncodedQuery {
            let kept = query.split(separator: "&", omittingEmptySubsequences: false).filter { field in
                let name = String(field.prefix { $0 != "=" })
                return !ephemeralQueryKeys.contains((name.removingPercentEncoding ?? name).lowercased())
            }
            components.percentEncodedQuery = kept.isEmpty ? nil : kept.joined(separator: "&")
        }
        // Only equivalent numbered edges serving a content-addressed novel cover share a key.
        if components.path.range(of: #"^/novel-pic/[0-9a-fA-F]{32}(?:~|$)"#, options: .regularExpression) != nil {
            components.host = host.replacingOccurrences(of: #"^p[0-9]+-"#, with: "p-", options: .regularExpression)
        }
        return components.string ?? trimmed
    }

    /// Deterministic SHA-256 disk filename for `urlString`.
    public static func diskFilename(for urlString: String) -> String {
        let key = normalizedKey(for: urlString)
        let digest = SHA256.hash(data: Data(key.utf8))
        let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return "\(hex).img"
    }
}
