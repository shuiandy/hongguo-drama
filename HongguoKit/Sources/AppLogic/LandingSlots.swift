import Foundation

/// The cold-start landing file keeps one saved clip per feed channel (`{"slots": {tab: entry}}`),
/// so leaving the app on 真人剧 does not cost 推荐 its instant start. A file in the earlier
/// single-entry format (one entry carrying its own tab) is read into the slot of that tab.
public enum LandingSlots {
    private struct File<Entry: Codable>: Codable {
        var slots: [String: Entry]
    }

    /// The slots in `data`; empty when it is neither format.
    public static func decode<Entry: Codable>(_ data: Data, as type: Entry.Type, legacyTab: (Entry) -> String) -> [String: Entry] {
        let decoder = JSONDecoder()
        if let file = try? decoder.decode(File<Entry>.self, from: data) { return file.slots }
        if let single = try? decoder.decode(Entry.self, from: data) { return [legacyTab(single): single] }
        return [:]
    }

    public static func encode<Entry: Codable>(_ slots: [String: Entry]) -> Data? {
        try? JSONEncoder().encode(File(slots: slots))
    }

    /// `existing` with `entry` stored under `tab`; other channels keep theirs.
    public static func storing<Entry: Codable>(_ entry: Entry, tab: String, in existing: Data?, legacyTab: (Entry) -> String) -> Data? {
        var slots = existing.map { decode($0, as: Entry.self, legacyTab: legacyTab) } ?? [:]
        slots[tab] = entry
        return encode(slots)
    }
}
