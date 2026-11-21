// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Observation
import HongguoCore

/// The Mac app's other catalogues settings: which built-in sources are on and the user's custom
/// Apple CMS endpoints. Kept apart from HongguoKit's `AppSettings`, which holds Hongguo only.
public struct SourceSettings: Codable, Equatable, Sendable {
    /// 西饭/河马 (on unless false) and ReelShort/DramaBox (off unless true); Hongguo is always on.
    public var builtinSources: [String: Bool] = [:]
    /// Apple CMS (`/api.php/provide/vod/`) endpoints added by the user.
    public var customSources: [CustomSourceConfig] = []

    public init(builtinSources: [String: Bool] = [:], customSources: [CustomSourceConfig] = []) {
        self.builtinSources = builtinSources; self.customSources = customSources
    }

    enum CodingKeys: String, CodingKey { case builtinSources, customSources }

    /// An entry that no longer validates is dropped instead of failing the whole value.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        builtinSources = (try? c.decodeIfPresent([String: Bool].self, forKey: .builtinSources)) ?? [:]
        customSources = ((try? c.decodeIfPresent([Lenient<CustomSourceConfig>].self, forKey: .customSources)) ?? []).compactMap { entry in
            entry.value.flatMap { try? CustomSource.validate($0) }.flatMap { $0.id.isEmpty ? nil : $0 }
        }
    }

    /// Sources shown in the switcher, in order.
    public var mediaSources: [MediaSources.Entry] { MediaSources.enabled(builtinSources, custom: customSources) }

    /// Turns a built-in source on or off. Hongguo cannot be turned off.
    public mutating func setBuiltinSource(_ id: String, enabled: Bool) throws {
        if id == "hongguo" { throw HongguoError(.input, "红果来源固定开启，不能关闭") }
        guard ["xifan", "hema", "reelshort", "dramabox"].contains(id) else { throw HongguoError(.input, "来源开关无效") }
        builtinSources[id] = enabled
    }

    /// Adds or replaces a custom source after validation; returns the stored entry.
    @discardableResult
    public mutating func saveCustomSource(_ draft: CustomSourceConfig) throws -> CustomSourceConfig {
        var source = try CustomSource.validate(draft)
        if let index = customSources.firstIndex(where: { $0.id == source.id }) { customSources[index] = source }
        else {
            if source.id.isEmpty { source.id = UUID().uuidString.lowercased() }
            customSources.append(source)
        }
        return source
    }

    public mutating func removeCustomSource(id: String) throws {
        guard customSources.contains(where: { $0.id == id.lowercased() }) else { throw HongguoError(.input, "播放源不存在") }
        customSources.removeAll { $0.id == id.lowercased() }
    }
}

/// Decodes one array element without failing the whole array.
struct Lenient<Value: Decodable>: Decodable {
    var value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

/// `SourceSettings` in the app's preferences, observable by views and safe to read from any task
/// (the source router reads it off the main actor). Every change is written back at once.
/// The first read takes the values an older build kept in library.json's settings, if any: the app
/// creates `shared` before `LibraryStore` can rewrite that file without them.
@Observable
public final class SourceSettingsStore: @unchecked Sendable {
    public static let shared = SourceSettingsStore()
    static let defaultsKey = "HongguoMediaSourceSettings.v1"
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var storage: SourceSettings

    public var value: SourceSettings {
        get {
            access(keyPath: \.value)
            lock.lock(); defer { lock.unlock() }
            return storage
        }
        set {
            withMutation(keyPath: \.value) {
                lock.lock()
                storage = newValue
                let data = try? JSONEncoder().encode(newValue)
                lock.unlock()
                if let data { defaults.set(data, forKey: Self.defaultsKey) }
            }
        }
    }

    /// Changes the settings in one step under the lock (no lost update between a read and a write).
    @discardableResult
    public func update<T>(_ change: (inout SourceSettings) throws -> T) rethrows -> T {
        var result: T?
        try withMutation(keyPath: \.value) {
            lock.lock()
            defer { lock.unlock() }
            var copy = storage
            result = try change(&copy)
            storage = copy
            if let data = try? JSONEncoder().encode(copy) { defaults.set(data, forKey: Self.defaultsKey) }
        }
        return result!
    }

    public init(defaults: UserDefaults = .standard, legacyLibrary: URL? = SourceSettingsStore.legacyLibraryURL) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey), let value = try? JSONDecoder().decode(SourceSettings.self, from: data) {
            storage = value
        } else {
            let initial = legacyLibrary.flatMap(Self.legacy) ?? SourceSettings()
            storage = initial
            if let data = try? JSONEncoder().encode(initial) { defaults.set(data, forKey: Self.defaultsKey) }
        }
    }

    public static var legacyLibraryURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("HongguoDrama/library.json")
    }

    /// `settings.builtinSources` and `settings.customSources` of library.json.
    static func legacy(_ url: URL) -> SourceSettings? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let settings = root["settings"] as? [String: Any] else { return nil }
        let subset = settings.filter { ["builtinSources", "customSources"].contains($0.key) }
        guard !subset.isEmpty, let json = try? JSONSerialization.data(withJSONObject: subset) else { return nil }
        return try? JSONDecoder().decode(SourceSettings.self, from: json)
    }
}
