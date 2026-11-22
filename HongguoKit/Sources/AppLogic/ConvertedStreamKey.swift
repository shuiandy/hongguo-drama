import Foundation

/// Names of the on-device ByteVC2 conversions (`ByteVC2Stream`): one folder per episode and
/// quality, `<vid>-<short side>` (0 when the quality is unknown), and the rules that pick or
/// drop them. Kept apart from the converter so they can be tested.
public enum ConvertedStreamKey {
    public static func make(vid: String, shortSide: Int?) -> String { "\(vid)-\(shortSide ?? 0)" }

    /// The episode a key belongs to (video ids are digits only, so the last `-` splits).
    public static func vid(of key: String) -> String? {
        guard let dash = key.lastIndex(of: "-") else { return nil }
        return String(key[..<dash])
    }

    /// The short side a key was converted at; nil when it was unknown (0).
    public static func shortSide(of key: String) -> Int? {
        guard let dash = key.lastIndex(of: "-"), let side = Int(key[key.index(after: dash)...]), side > 0 else { return nil }
        return side
    }

    /// A finished conversion and the short sides the source offered when it was made (nil
    /// when that was not recorded, as in folders written before it was).
    public struct Finished: Equatable, Sendable {
        public var key: String
        public var offered: [Int]?
        public init(key: String, offered: [Int]?) { self.key = key; self.offered = offered }
    }

    /// The tier a lookup would pick for a preference among the offered short sides, the way
    /// `PlayInfo.selecting(shortSide:)` does: the best at or below it, else the lowest.
    public static func tier(for preferred: Int, offered: [Int]) -> Int? {
        let sorted = offered.sorted(by: >)
        return sorted.first { $0 <= preferred } ?? sorted.last
    }

    /// Which finished conversion of `vid` may play without a source lookup. `finished` is most
    /// recently used first. With no quality chosen (`preferredShortSide` nil) any of them will
    /// do. Once the viewer has chosen one, a conversion counts only if it is at the tier a
    /// lookup would pick for that choice: a kept 360P must not stand in for a chosen 720P, but
    /// a kept 720P does serve a 1080P choice when 720P was the best the source had. A source
    /// with one tier offers no choice (empty list); a folder that did not record what was
    /// offered needs an exact match.
    public static func pick(finished: [Finished], vid: String, preferredShortSide: Int?) -> String? {
        let mine = finished.filter { self.vid(of: $0.key) == vid }
        guard let preferredShortSide else { return mine.first?.key }
        return mine.first { item in
            guard let offered = item.offered else { return shortSide(of: item.key) == preferredShortSide }
            guard let wanted = tier(for: preferredShortSide, offered: offered) else { return true }
            return shortSide(of: item.key) == wanted
        }?.key
    }

    /// A conversion started ahead of time that the viewer no longer needs: it is for none of the
    /// episodes in `keeping` (the one on screen and the one expected next). It gives way, so a
    /// card the viewer swiped past does not keep the converter (and the CPU) from the one they
    /// are watching. A conversion the viewer opened is never stale here.
    public static func isStaleAhead(jobKey: String, isAhead: Bool, keeping: Set<String>) -> Bool {
        guard isAhead, let vid = vid(of: jobKey) else { return false }
        return !keeping.contains(vid)
    }
}
