// Mac only: replaces the running .app bundle and relaunches it.
#if os(macOS)

import CryptoKit
import Foundation
import Security

/// 应用内更新 (port of the idea behind app-update-installer.js for the native app): downloads the
/// release archive, checks its SHA-256 against GitHub's digest, unpacks it, checks the code
/// signature, and on request replaces the running app and relaunches it.
///
/// Signature rule: the new app must pass a strict signature check, carry the same bundle
/// identifier, and come from the same team as the running app. A locally signed build (no team)
/// only accepts a Developer ID signed update.
public actor AppUpdateInstaller {
    public static let shared = AppUpdateInstaller()

    public enum Phase: Equatable, Sendable {
        case idle
        case downloading(received: Int64, total: Int64)
        case verifying
        case ready(version: String)
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    private var staged: (version: String, app: URL)?
    private var observers: [UUID: AsyncStream<Phase>.Continuation] = [:]
    private var running: Task<Void, Never>?

    public func updates() -> AsyncStream<Phase> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Phase>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.yield(phase)
        continuation.onTermination = { _ in Task { await self.removeObserver(id) } }
        return stream
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    private func set(_ value: Phase) {
        phase = value
        for continuation in observers.values { continuation.yield(value) }
    }

    /// Where the running app lives; installing needs write access to its folder.
    public static var installedAppURL: URL { Bundle.main.bundleURL }

    public static var canReplaceInstalledApp: Bool {
        let app = installedAppURL
        return app.pathExtension == "app" && FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path)
    }

    /// Starts (or restarts) downloading and verifying `release`.
    public func prepare(_ release: AvailableRelease) {
        guard let asset = release.asset else {
            set(.failed("这个版本没有可在应用内安装的文件，请到发布页下载"))
            return
        }
        if case .ready(let version) = phase, version == release.version { return }
        running?.cancel()
        running = Task { await self.run(version: release.version, asset: asset) }
    }

    public func cancel() {
        running?.cancel()
        running = nil
        set(.idle)
    }

    private func run(version: String, asset: ReleaseAsset) async {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("HongguoDrama-update-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            set(.downloading(received: 0, total: asset.size))
            let archive = work.appendingPathComponent("update.zip")
            try await Self.download(asset, to: archive) { received in
                Task { await self.set(.downloading(received: received, total: asset.size)) }
            }
            try Task.checkCancellation()
            set(.verifying)
            guard try Self.sha256(of: archive) == asset.sha256 else {
                throw HongguoError(.security, "更新文件校验失败，已丢弃，请稍后重试")
            }
            let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
            try Self.runTool("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])
            try? FileManager.default.removeItem(at: archive)
            let apps = (try FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)).filter { $0.pathExtension == "app" }
            guard apps.count == 1, let app = apps.first else { throw HongguoError(.format, "更新文件内容不完整") }
            try Self.verifySignature(of: app)
            guard let newVersion = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                  UpdateChecker.versionParts(newVersion) != nil else { throw HongguoError(.format, "更新文件缺少版本信息") }
            staged = (version, app)
            set(.ready(version: version))
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: work)
            set(.idle)
        } catch {
            try? FileManager.default.removeItem(at: work)
            set(.failed((error as? HongguoError)?.message ?? "下载更新失败：\(error.localizedDescription)"))
        }
    }

    /// Replaces the running app with the staged one and relaunches. A helper shell waits for
    /// this process to quit, swaps the bundle (the old one goes to the Trash folder of the user),
    /// and opens the new app. The caller should then terminate the app.
    public func installAndRelaunch() throws {
        guard let staged else { throw HongguoError(.input, "更新还没有准备好") }
        guard Self.canReplaceInstalledApp else {
            throw HongguoError(.input, "没有权限替换 \(Self.installedAppURL.deletingLastPathComponent().path) 里的应用，请手动拖入新版本")
        }
        let target = Self.installedAppURL
        let trash = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let old = trash.appendingPathComponent("\(target.deletingPathExtension().lastPathComponent) \(UpdateChecker.currentVersion).app")
        let script = """
        pid="$1"; new="$2"; target="$3"; old="$4"
        for _ in $(seq 1 120); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
        rm -rf "$old"
        mv "$target" "$old" || exit 1
        if ! /usr/bin/ditto "$new" "$target"; then rm -rf "$target"; mv "$old" "$target"; /usr/bin/open "$target"; exit 1; fi
        /usr/bin/xattr -dr com.apple.quarantine "$target" 2>/dev/null
        /usr/bin/open "$target"
        rm -rf "$(dirname "$new")"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "hongguo-update", String(ProcessInfo.processInfo.processIdentifier),
                             staged.app.path, target.path, old.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    // MARK: Steps

    static func download(_ asset: ReleaseAsset, to file: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let config = HTTPClient.defaultConfiguration()
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: asset.url)
        request.setValue("Hongguo-Drama-macOS", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        // Redirects go to GitHub's asset storage only.
        guard let final = response.url, final.scheme == "https", let host = final.host,
              ReleaseAsset.allowedHosts.contains(host) || host.hasSuffix(".githubusercontent.com") else {
            throw HongguoError(.security, "更新下载地址异常，已停止")
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw HongguoError(.upstream, "更新文件下载失败") }
        FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var received: Int64 = 0
        var lastReport = Date.distantPast
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                guard received <= asset.size else { throw HongguoError(.security, "更新文件大小不符，已停止") }
                if Date().timeIntervalSince(lastReport) > 0.3 { progress(received); lastReport = Date() }
                try Task.checkCancellation()
            }
        }
        try handle.write(contentsOf: buffer)
        received += Int64(buffer.count)
        progress(received)
        guard received == asset.size else { throw HongguoError(.security, "更新文件大小不符，已丢弃") }
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func runTool(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw HongguoError(.format, "更新文件无法解压") }
    }

    /// Strict signature check plus identity: same bundle id, same team (or Developer ID when the
    /// running build has no team).
    static func verifySignature(of app: URL) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw HongguoError(.security, "无法读取新版本的签名")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let currentTeam = teamIdentifier(ofRunning: ())
        let bundleId = Bundle.main.bundleIdentifier ?? "io.github.shuiandy.hongguo-drama.native"
        let requirementText: String
        if let currentTeam {
            requirementText = "identifier \"\(bundleId)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(currentTeam)\""
        } else {
            // Developer ID Application certificates carry this marker OID.
            requirementText = "identifier \"\(bundleId)\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess, let requirement else {
            throw HongguoError(.security, "无法建立签名校验条件")
        }
        let status = SecStaticCodeCheckValidity(code, flags, requirement)
        guard status == errSecSuccess else {
            throw HongguoError(.security, "新版本的签名与当前应用不一致，已拒绝安装（\(status)）")
        }
    }

    /// Team id of the running app, nil for ad-hoc or locally signed builds.
    static func teamIdentifier(ofRunning _: Void) -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

#endif
