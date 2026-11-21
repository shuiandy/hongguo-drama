import Foundation

/// Where HongguoKit keeps its files on disk. One place for every store: `LibraryStore`,
/// `SeriesLibrary` and every `JSONFileStore` (downloads list, announcements) resolve their
/// folder through here.
///
/// The default is Application Support, which is what the Mac and iOS apps have always used, so
/// they never need to call `configure`. An app whose platform keeps no persistent local storage
/// (tvOS) points the base at its Caches folder once at launch and passes a `UserDefaults` that
/// mirrors the small state (settings and the most recent watch progress), so a purge of Caches
/// does not lose them. This is a location, not a behavior switch: the stores work the same way
/// wherever the folder is.
///
/// Call `configure` first thing at launch, before anything touches `LibraryStore.shared`,
/// `SeriesLibrary.shared` or another store: those are created lazily on first use and keep the
/// folder they were created with.
public enum StorageRoot {
    private struct State {
        var base: URL?
        var mirror: UserDefaults?
        var wasRead = false
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var state = State()

    /// Points every store at `base` (instead of Application Support) and, when given, mirrors the
    /// small state into `mirror`.
    public static func configure(base: URL, mirror: UserDefaults? = nil) {
        lock.lock(); defer { lock.unlock() }
        assert(!state.wasRead, "StorageRoot.configure must run before the first store is created")
        state.base = base
        state.mirror = mirror
    }

    /// The folder app data lives in: Application Support unless `configure` chose another.
    /// A few app files sit directly in it (the iOS app's episode positions and reservations).
    public static var base: URL {
        lock.lock(); defer { lock.unlock() }
        state.wasRead = true
        return state.base ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// `base/HongguoDrama`: library, series library, downloads list, announcements.
    public static var appFolder: URL {
        base.appendingPathComponent("HongguoDrama", isDirectory: true)
    }

    /// Where small state is mirrored, or nil (the default) when the base folder is persistent.
    public static var mirror: UserDefaults? {
        lock.lock(); defer { lock.unlock() }
        state.wasRead = true
        return state.mirror
    }
}
