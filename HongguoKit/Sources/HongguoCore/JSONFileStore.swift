import Foundation

/// Atomic JSON file persistence for one Codable value. A file that fails to decode is moved
/// aside (`name.damaged-<time>.json`) and the default value is used, so a bad file never crashes
/// the app or silently overwrites the user's data without a backup.
public struct JSONFileStore<Value: Codable>: Sendable {
    public let url: URL

    public init(directory: URL, name: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        url = directory.appendingPathComponent(name)
    }

    /// `StorageRoot.appFolder`: Application Support/HongguoDrama unless the app chose another base.
    public static var defaultDirectory: URL { StorageRoot.appFolder }

    public func load(default fallback: @autoclosure () -> Value) -> Value {
        guard let data = try? Data(contentsOf: url) else { return fallback() }
        if let value = try? JSONDecoder.library.decode(Value.self, from: data) { return value }
        let stem = url.deletingPathExtension().lastPathComponent
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("\(stem).damaged-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: url, to: backup)
        return fallback()
    }

    public func save(_ value: Value) throws {
        let data = try JSONEncoder.library.encode(value)
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
