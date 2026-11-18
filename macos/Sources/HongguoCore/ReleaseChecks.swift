import Foundation

/// The GitHub repository that serves releases and announcements (port of release-repo.js).
/// Forks change only this.
public enum ReleaseRepo {
    public static let slug = "shuiandy/hongguo-drama"
    public static let releasesURL = URL(string: "https://github.com/\(slug)/releases")!
    public static let latestReleaseAPI = URL(string: "https://api.github.com/repos/\(slug)/releases/latest")!
    public static let rawMain = "https://raw.githubusercontent.com/\(slug)/main"
}

public struct AvailableRelease: Equatable, Sendable {
    public var version: String
    /// Always this project's own release page, never a URL taken from the response.
    public var url: URL
}

/// Checks the latest GitHub release (port of app-update.js `availableRelease`). Only reports;
/// installing stays with the user (or a later Sparkle integration).
public final class UpdateChecker: Sendable {
    private let http: HTTPClient
    public init(http: HTTPClient = .shared) { self.http = http }

    public static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// `v1.2` / `1.2.3` to three integers.
    public static func versionParts(_ value: String) -> [Int]? {
        let pattern = "^v?(\\d+)\\.(\\d+)(?:\\.(\\d+))?$"
        guard let match = HTMLData.firstMatch(pattern, in: value) else { return nil }
        let parts = [match[1], match[2], match.count > 3 && !match[3].isEmpty ? match[3] : "0"].map { Int($0) }
        guard parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.map { $0! }
    }

    /// A newer, non-draft, non-prerelease release, or nil.
    public static func availableRelease(_ data: JSONValue, currentVersion: String) -> AvailableRelease? {
        guard data.object != nil, data["draft"].bool != true, data["prerelease"].bool != true,
              let tag = data["tag_name"].string, let next = versionParts(tag), let current = versionParts(currentVersion),
              let difference = next.indices.first(where: { next[$0] != current[$0] }), next[difference] > current[difference]
        else { return nil }
        var version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        if version.hasSuffix(".0"), version.split(separator: ".").count == 3 { version.removeLast(2) }
        // The tag passed `versionParts`, so it is only digits, dots and an optional "v".
        return AvailableRelease(version: version, url: ReleaseRepo.releasesURL.appendingPathComponent("tag").appendingPathComponent(tag))
    }

    public func check(currentVersion: String = UpdateChecker.currentVersion) async throws -> AvailableRelease? {
        var options = HTTPClient.Options()
        options.headers = ["Accept": "application/vnd.github+json", "User-Agent": "Hongguo-Drama-macOS"]
        options.timeout = 10
        options.maxBytes = 1024 * 1024
        let response = try await http.get(ReleaseRepo.latestReleaseAPI, options: options)
        return Self.availableRelease(try JSONValue.parse(response.data), currentVersion: currentVersion)
    }
}

// MARK: - Announcements

public struct Announcement: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var body: String
    public var urgent: Bool
}

/// Remote announcements from `announcements/{normal,emergency}.json` on the main branch. Port of
/// app-announcements.js: strict schema, 32 KB cap, emergency checked at most every 5 minutes and
/// shown until acknowledged, normal ones can be muted for the day or for this version.
public actor AnnouncementService {
    public struct State: Codable, Equatable, Sendable {
        public var normalEnabled = true
        public var emergencyEnabled = true
        public var seenUrgentIds: [String] = []
        public var suppressionMode: String?
        public var suppressionVersion: String?
        public var suppressionDay: String?
    }

    public enum Mute: String, Sendable { case day, version }

    static let maxBytes = 32 * 1024
    static let emergencyInterval: TimeInterval = 5 * 60

    private let fetch: @Sendable (URL) async throws -> (status: Int, contentType: String, body: Data)
    private let store: JSONFileStore<State>?
    private let version: String
    private let now: @Sendable () -> Date
    private var state: State
    private var lastEmergencyAttempt = Date.distantPast
    private var latestEmergency: Announcement?
    private var shownUrgentIds = Set<String>()

    public init(version: String = UpdateChecker.currentVersion,
                store: JSONFileStore<State>? = JSONFileStore(directory: JSONFileStore<State>.defaultDirectory, name: "announcements.json"),
                now: @escaping @Sendable () -> Date = { Date() },
                fetch: (@Sendable (URL) async throws -> (status: Int, contentType: String, body: Data))? = nil) {
        self.version = version
        self.store = store
        self.now = now
        self.state = store?.load(default: State()) ?? State()
        self.fetch = fetch ?? { url in
            var options = HTTPClient.Options()
            options.headers = ["Accept": "application/json", "User-Agent": "Hongguo-Drama-Announcements"]
            options.timeout = 6
            options.maxRedirects = 0
            options.maxBytes = AnnouncementService.maxBytes
            let response = try await HTTPClient.shared.get(url, options: options)
            return (response.status, response.header("Content-Type") ?? "", response.data)
        }
    }

    public var preferences: State { state }

    static func url(_ channel: String) -> URL { URL(string: "\(ReleaseRepo.rawMain)/announcements/\(channel).json")! }

    static func validId(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", options: .regularExpression) != nil
    }

    static func validText(_ value: String, limit: Int, multiline: Bool) -> Bool {
        guard value.utf16.count <= limit, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        for scalar in value.unicodeScalars {
            let v = scalar.value
            if scalar == "<" || scalar == ">" || v == 0x7F { return false }
            if v < 0x20 {
                let allowed: [UInt32] = multiline ? [0x09, 0x0A, 0x0D] : []
                if !allowed.contains(v) { return false }
            }
        }
        return true
    }

    /// Exactly `{id, title, body, active: true}`; anything else is ignored.
    public static func parse(status: Int, contentType: String, body: Data, urgent: Bool) -> Announcement? {
        guard status == 200, body.count <= maxBytes else { return nil }
        let type = contentType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        guard ["application/json", "text/plain"].contains(type), let json = try? JSONValue.parse(body), let object = json.object,
              object.count == 4, json["active"].bool == true,
              let id = json["id"].string, validId(id),
              let title = json["title"].string, validText(title, limit: 120, multiline: false),
              let text = json["body"].string, validText(text, limit: 4000, multiline: true) else { return nil }
        return Announcement(id: id, title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                            body: text.trimmingCharacters(in: .whitespacesAndNewlines), urgent: urgent)
    }

    private func load(_ channel: String) async -> Announcement? {
        guard let response = try? await fetch(Self.url(channel)) else { return nil }
        return Self.parse(status: response.status, contentType: response.contentType, body: response.body, urgent: channel == "emergency")
    }

    private var localDay: String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: now())
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private var normalSuppressed: Bool {
        state.suppressionVersion == version && (state.suppressionMode == "version"
            || (state.suppressionMode == "day" && state.suppressionDay == localDay))
    }

    /// The announcement to show at launch or on a timer: an unseen emergency first, else the
    /// normal one unless muted.
    public func check(urgentOnly: Bool = false) async -> Announcement? {
        if state.emergencyEnabled {
            if now().timeIntervalSince(lastEmergencyAttempt) >= Self.emergencyInterval {
                lastEmergencyAttempt = now()
                latestEmergency = await load("emergency")
            }
            if let emergency = latestEmergency, state.emergencyEnabled, !state.seenUrgentIds.contains(emergency.id) {
                shownUrgentIds.insert(emergency.id)
                return emergency
            }
        }
        guard !urgentOnly, state.normalEnabled, !normalSuppressed else { return nil }
        let normal = await load("normal")
        return state.normalEnabled && !normalSuppressed ? normal : nil
    }

    /// "View announcement" in settings: whatever is current, ignoring mutes.
    public func current() async -> Announcement? {
        async let emergency = load("emergency")
        async let normal = load("normal")
        let result = await emergency ?? normal
        if let result, result.urgent { shownUrgentIds.insert(result.id) }
        return result
    }

    /// Marks an emergency announcement as read so it is not shown again.
    public func acknowledge(_ id: String) throws {
        guard Self.validId(id), shownUrgentIds.contains(id) else { throw HongguoError(.input, "公告无效或尚未展示。") }
        if !state.seenUrgentIds.contains(id) { state.seenUrgentIds.append(id) }
        try save("公告已在本次运行中记为已读，但未能保存；重启后可能再次显示。")
    }

    public func mute(_ mode: Mute) throws {
        state.suppressionMode = mode.rawValue
        state.suppressionVersion = version
        state.suppressionDay = localDay
        try save("普通公告免提醒设置保存失败，请检查磁盘空间或目录权限后重试。")
    }

    public func setPreferences(normalEnabled: Bool? = nil, emergencyEnabled: Bool? = nil) throws {
        if let normalEnabled { state.normalEnabled = normalEnabled }
        if let emergencyEnabled {
            state.emergencyEnabled = emergencyEnabled
            if !emergencyEnabled { latestEmergency = nil }
        }
        try save("公告开关保存失败，请检查磁盘空间或目录权限后重试。")
    }

    private func save(_ message: String) throws {
        do { try store?.save(state) } catch { throw HongguoError(.input, message) }
    }
}
