import Foundation

/// ByteVC2 兼容转换 (port of src/native/bytevc2.js). Some episodes are only offered in ByteVC2,
/// which no Apple decoder plays. The separate `librempeg` helper (AGPL, built by
/// scripts/build-librempeg.sh and bundled as Contents/Resources/bin/librempeg) decrypts and
/// decodes it on the CPU and encodes H.264 (VideoToolbox first on Apple silicon, then x264).
/// Conversions run one at a time, like the Electron queue, so downloads and the player share one
/// CPU budget.
public actor ByteVC2Converter {
    public static let shared = ByteVC2Converter()

    /// Whether ByteVC2 rows may be chosen at all: the setting is on and the helper exists.
    /// Read synchronously by the App source parser.
    public static var isEnabled: Bool { state.withLock { $0.enabled && $0.executable != nil } }
    public static var executableURL: URL? { state.withLock { $0.executable } }
    public static var fastConversion: Bool { state.withLock { $0.fast } }

    private struct State { var enabled = true; var fast = false; var executable: URL? = ByteVC2Converter.locateExecutable() }
    private static let state = LockedValue(State())

    public static func configure(enabled: Bool, fast: Bool) {
        state.withLock { $0.enabled = enabled; $0.fast = fast }
    }

    /// Tests: pretend the helper is (not) installed.
    static func setExecutableForTesting(_ url: URL?) { state.withLock { $0.executable = url } }

    /// The helper: `HONGGUO_LIBREMPEG`, inside this app, or (for development and as a fallback)
    /// the one shipped with the installed Electron app.
    static func locateExecutable() -> URL? {
        var candidates: [URL] = []
        if let path = ProcessInfo.processInfo.environment["HONGGUO_LIBREMPEG"], !path.isEmpty {
            candidates.append(URL(fileURLWithPath: path))
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("bin/librempeg"))
        }
        candidates.append(URL(fileURLWithPath: "/Applications/红果短剧.app/Contents/Resources/bin/librempeg"))
        let fm = FileManager.default
        for url in candidates {
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue, fm.isExecutableFile(atPath: url.path) {
                return url.resolvingSymlinksInPath()
            }
        }
        return nil
    }

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    /// Converts `input` (encrypted when `key` is given) to an H.264 MP4 at `output`.
    /// `progress` receives converted seconds. Cancelling the task stops the helper.
    public func convert(input: URL, output: URL, key: [UInt8]?, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard let executable = Self.executableURL else {
            throw HongguoError(.unavailable, "未找到 ByteVC2 解码组件，请重新安装完整版本后重试")
        }
        if let key, key.count != 16 { throw HongguoError(.decrypt, "片源解密密钥格式无效") }
        guard input != output else { throw HongguoError(.input, "ByteVC2 视频参数无效") }
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        let fast = Self.fastConversion
        #if arch(arm64)
        let encoders = ["h264_videotoolbox", "libx264"]
        #else
        let encoders = ["libx264"]
        #endif
        var lastError: Error = HongguoError(.unavailable, "ByteVC2 转码失败")
        for encoder in encoders {
            try Task.checkCancellation()
            try? FileManager.default.removeItem(at: output)
            do {
                try await Self.run(executable: executable, arguments: Self.arguments(input: input, output: output, key: key,
                                                                                    encoder: encoder, fast: fast),
                                   progress: progress)
                let size = ((try? FileManager.default.attributesOfItem(atPath: output.path)[.size]) as? NSNumber)?.int64Value ?? 0
                guard size > 0 else { throw HongguoError(.format, "ByteVC2 转码结果不完整，请重试本集") }
                return
            } catch let error as ConversionFailure where error.encoderProblem && encoder != "libx264" {
                // VideoToolbox unavailable or refused: retry once with x264.
                lastError = error
                continue
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: output)
                throw CancellationError()
            } catch {
                try? FileManager.default.removeItem(at: output)
                throw error
            }
        }
        try? FileManager.default.removeItem(at: output)
        throw lastError
    }

    static func arguments(input: URL, output: URL, key: [UInt8]?, encoder: String, fast: Bool) -> [String] {
        let keyArgs = key.map { ["-decryption_key", $0.map { String(format: "%02x", $0) }.joined()] } ?? []
        let video = encoder == "h264_videotoolbox"
            ? ["-c:v", encoder, "-allow_sw", "0", "-realtime", "0", "-q:v", "68", "-profile:v", "high", "-pix_fmt", "yuv420p", "-threads:v", "2"]
            : ["-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-pix_fmt", "yuv420p", "-threads:v", "2", "-x264-params", "lookahead_threads=1"]
        return ["-y", "-hide_banner", "-loglevel", "error", "-xerror", "-nostdin", "-protocol_whitelist", "file,pipe",
                "-filter_threads", "1", "-threads:v", fast ? "4" : "2"] + keyArgs + ["-i", input.path,
                "-map", "0:v:0", "-map", "0:a?"] + video + ["-c:a", "copy", "-movflags", "+faststart",
                "-progress", "pipe:1", "-nostats", "-f", "mp4", output.path]
    }

    struct ConversionFailure: LocalizedError {
        var encoderProblem: Bool
        var errorDescription: String? { "ByteVC2 转码失败，请重新获取片源后重试" }
    }

    /// Runs the helper; stdout carries `-progress` lines, stderr is classified but never shown
    /// (it can contain the key and paths).
    static func run(executable: URL, arguments: [String], progress: (@Sendable (Double) -> Void)?) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin"]
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        let diagnostics = LockedValue("")
        let buffer = LockedValue("")
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = String(decoding: handle.availableData, as: UTF8.self)
            let lines: [String] = buffer.withLock { text in
                text += chunk
                var parts = text.components(separatedBy: "\n")
                text = parts.removeLast()
                return parts
            }
            for line in lines where line.hasPrefix("out_time_us=") {
                if let micro = Double(line.dropFirst("out_time_us=".count)), micro >= 0 { progress?(micro / 1_000_000) }
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = String(decoding: handle.availableData, as: UTF8.self)
            diagnostics.withLock { $0 = String(($0 + chunk).suffix(65536)) }
        }
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do { try process.run() } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: HongguoError(.unavailable, "无法启动 ByteVC2 解码组件"))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        try Task.checkCancellation()
        guard status == 0 else {
            let text = diagnostics.withLock { $0 }
            if text.range(of: "No space left|Disk quota|File too large", options: [.regularExpression, .caseInsensitive]) != nil {
                throw HongguoError(.input, "磁盘空间不足，ByteVC2 转码未完成")
            }
            let encoderProblem = text.range(of: "Unknown encoder|compression session|h264_videotoolbox[^\\n]*(error|failed)|Error while opening encoder",
                                            options: [.regularExpression, .caseInsensitive]) != nil
            throw ConversionFailure(encoderProblem: encoderProblem)
        }
    }
}

/// A value behind a lock, for state shared with synchronous callers.
final class LockedValue<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body(&value)
    }
}
