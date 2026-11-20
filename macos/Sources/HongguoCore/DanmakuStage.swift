// SPDX-License-Identifier: GPL-3.0-only
// Danmaku display model: settings, word filter, lane layout and the time-driven emitter.
// Ports of src/components/danmakuModel.mjs and danmakuOfficial.mjs (adapted from
// dawei233/hongguo-drama, GPL-3.0). Pure value types: the view only draws `DanmakuStage.items`.
import Foundation

public struct DanmakuSettings: Codable, Equatable, Sendable {
    public enum Area: String, Codable, CaseIterable, Sendable { case quarter, half, full }
    public enum Density: String, Codable, CaseIterable, Sendable { case sparse, normal, dense }
    /// Where the bullets come from: timed danmaku, this episode's public comments, or timed danmaku
    /// with the comments as a fallback when the episode has none or the request fails.
    public enum Source: String, Codable, CaseIterable, Sendable { case auto, official, comments }

    public var enabled: Bool = true
    /// 20...100 (%).
    public var opacity: Double = 80
    /// 16...32 pt.
    public var fontSize: Double = 22
    /// 0.5...2.
    public var speed: Double = 1
    public var area: Area = .half
    public var density: Density = .normal
    public var sensitiveFilter: Bool = true
    /// User words separated by newlines, commas or semicolons (full or half width).
    public var blockedWords: String = ""
    public var source: Source = .auto

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DanmakuSettings()
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? d.enabled
        opacity = (try? c.decodeIfPresent(Double.self, forKey: .opacity)) ?? d.opacity
        fontSize = (try? c.decodeIfPresent(Double.self, forKey: .fontSize)) ?? d.fontSize
        speed = (try? c.decodeIfPresent(Double.self, forKey: .speed)) ?? d.speed
        area = (try? c.decodeIfPresent(Area.self, forKey: .area)) ?? d.area
        density = (try? c.decodeIfPresent(Density.self, forKey: .density)) ?? d.density
        sensitiveFilter = (try? c.decodeIfPresent(Bool.self, forKey: .sensitiveFilter)) ?? d.sensitiveFilter
        blockedWords = (try? c.decodeIfPresent(String.self, forKey: .blockedWords)) ?? d.blockedWords
        source = (try? c.decodeIfPresent(Source.self, forKey: .source)) ?? d.source
        self = normalized()
    }

    /// Clamps every field to the range the Electron settings panel allows.
    public func normalized() -> DanmakuSettings {
        var copy = self
        func clamp(_ v: Double, _ lo: Double, _ hi: Double, _ fallback: Double) -> Double { v.isFinite ? min(hi, max(lo, v)) : fallback }
        copy.opacity = clamp(opacity, 20, 100, 80)
        copy.fontSize = clamp(fontSize, 16, 32, 22)
        copy.speed = clamp(speed, 0.5, 2, 1)
        if copy.blockedWords.count > 10_000 { copy.blockedWords = String(copy.blockedWords.prefix(10_000)) }
        return copy
    }
}

public enum DanmakuFilter {
    static let builtinBlockedWords = ["习近平", "習近平", "共产党", "共產黨", "中国共产党", "中共", "国民党", "國民黨", "民进党", "民進黨",
        "毛泽东", "毛澤東", "邓小平", "鄧小平", "江泽民", "江澤民", "胡锦涛", "胡錦濤", "李克强", "李克強", "蔡英文", "赖清德", "賴清德",
        "台独", "台獨", "港独", "港獨", "藏独", "藏獨", "疆独", "疆獨", "六四", "天安门事件", "天安門事件", "法轮功", "法輪功", "反共", "反华", "反華",
        "文革", "文化大革命", "政治局", "颠覆政权", "顛覆政權", "操你妈", "操你媽", "傻逼", "傻屄"]

    /// NFKC, lowercase, and without whitespace or invisible direction/zero-width characters.
    static func comparable(_ text: String) -> String {
        let folded = text.precomposedStringWithCompatibilityMapping.lowercased()
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter { scalar in
            let v = scalar.value
            if scalar.properties.isWhitespace { return false }
            return !((0x200B...0x200F).contains(v) || (0x202A...0x202E).contains(v) || (0x2060...0x2069).contains(v) || v == 0xFEFF)
        }))
    }

    public static func words(_ settings: DanmakuSettings) -> [String] {
        var list = settings.blockedWords.split(whereSeparator: { "\n,，;；".contains($0) }).map { comparable(String($0)) }.filter { !$0.isEmpty }
        if settings.sensitiveFilter { list += builtinBlockedWords }
        return list
    }

    public static func isBlocked(_ text: String, settings: DanmakuSettings) -> Bool {
        isBlocked(text, words: words(settings))
    }

    public static func isBlocked(_ text: String, words: [String]) -> Bool {
        let value = comparable(text)
        return words.contains { value.contains($0) }
    }

    /// Shown text: at most 80 characters, with a "× n" suffix for merged duplicates.
    public static func displayText(_ content: String, count: Int = 1) -> String {
        let text = content.count > 80 ? String(content.prefix(79)) + "…" : content
        return count > 1 ? "\(text) × \(count)" : text
    }
}

/// One entry of the timeline. Identical text within 5 seconds collapses into one with a count.
public struct DanmakuEntry: Hashable, Sendable {
    public var time: Double
    public var text: String
    public var color: String
    public var mode: DanmakuMode
    public var count: Int

    public static func group(_ items: [DanmakuItem]) -> [DanmakuEntry] {
        var groups: [DanmakuEntry] = []
        var latest: [String: Int] = [:]
        for item in items {
            if let index = latest[item.text], item.time - groups[index].time <= 5 {
                groups[index].count += 1
            } else {
                groups.append(DanmakuEntry(time: item.time, text: item.text, color: item.color, mode: item.mode, count: 1))
                latest[item.text] = groups.count - 1
            }
        }
        return groups
    }
}

/// A comment currently on screen. Coordinates are in points from the top-left of the video.
public struct DanmakuSprite: Identifiable, Equatable, Sendable {
    public var id: Int
    public var text: String
    public var content: String
    public var entry: DanmakuEntry?
    public var color: String
    public var mode: DanmakuMode
    public var lane: Int
    public var x: Double
    public var y: Double
    public var width: Double
    public var age: Double
}

public struct DanmakuLayout: Equatable, Sendable {
    public var top: Double
    public var lineHeight: Double
    public var lanes: Int

    public static func make(height: Double, settings: DanmakuSettings, reducedMotion: Bool, bottomInset: Double = 76) -> DanmakuLayout {
        let top = 12.0
        let lineHeight = settings.fontSize + 12
        let fraction: Double = switch settings.area { case .quarter: 0.25; case .half: 0.5; case .full: 1 }
        let bottom = min(height - bottomInset, height * fraction)
        return DanmakuLayout(top: top, lineHeight: lineHeight, lanes: reducedMotion ? 1 : max(1, Int(((bottom - top) / lineHeight).rounded(.down))))
    }
}

/// Time-driven emitter for official danmaku. Call `advance` once per display frame with the
/// current media time; draw `items`. Seeks are detected from the time jump.
public struct DanmakuStage: Sendable {
    public struct Viewport: Sendable, Equatable {
        public var width: Double
        public var height: Double
        public var reducedMotion: Bool
        public var bottomInset: Double
        public init(width: Double, height: Double, reducedMotion: Bool = false, bottomInset: Double = 76) {
            self.width = width; self.height = height; self.reducedMotion = reducedMotion; self.bottomInset = bottomInset
        }
    }

    static let laneHeadGap = 24.0
    static let maxEmitPerFrame = 4
    static let staleSeconds = 5.0
    static let reducedMotionReadSeconds = 6.0
    /// Points per second at speed 1.
    static let baseSpeed = 85.0

    public private(set) var items: [DanmakuSprite] = []
    public private(set) var entries: [DanmakuEntry] = []
    private var settings: DanmakuSettings
    private var words: [String]
    private var nextId = 0
    private var cursor = 0
    private var cooldown = 0.0
    private var lastTime: Double?
    private var replayQueue: [(entry: DanmakuEntry?, content: String)] = []
    /// Text width estimate; the view can supply a real measurement.
    public var measure: @Sendable (String, Double) -> Double = { text, fontSize in Double(text.count + 1) * fontSize }

    public init(items: [DanmakuItem] = [], settings: DanmakuSettings = DanmakuSettings()) {
        self.settings = settings.normalized()
        self.words = DanmakuFilter.words(self.settings)
        load(items)
    }

    /// Replaces the timeline (for example after a fetch) without clearing comments on screen.
    public mutating func load(_ items: [DanmakuItem]) {
        entries = DanmakuEntry.group(items.sorted { $0.time < $1.time })
        lastTime = nil
    }

    public mutating func update(settings newValue: DanmakuSettings) {
        settings = newValue.normalized()
        words = DanmakuFilter.words(settings)
        items.removeAll { DanmakuFilter.isBlocked($0.content, words: words) }
    }

    public mutating func reset() {
        items.removeAll()
        replayQueue.removeAll()
        cursor = 0
        cooldown = 0
        lastTime = nil
    }

    /// First index whose time is >= `time`.
    public static func lowerBound(_ list: [DanmakuEntry], _ time: Double) -> Int {
        var low = 0, high = list.count
        while low < high {
            let mid = (low + high) / 2
            if list[mid].time < time { low = mid + 1 } else { high = mid }
        }
        return low
    }

    static func isSeek(_ last: Double?, _ current: Double, _ elapsed: Double) -> Bool {
        guard let last else { return true }
        let jump = current - last
        return jump < 0 || jump > elapsed * 3 + 1
    }

    private func blocked(_ text: String) -> Bool { DanmakuFilter.isBlocked(text, words: words) }

    /// Advances by `elapsed` media seconds (already multiplied by the playback rate). Returns
    /// whether anything changed. Pass `emitting: false` while paused to keep the cursor still.
    @discardableResult
    public mutating func advance(currentTime: Double, elapsed: Double, viewport: Viewport, emitting: Bool = true) -> Bool {
        guard viewport.width >= 40, viewport.height >= 60 else { return false }
        let reduced = viewport.reducedMotion
        let delta = min(max(elapsed, 0), 0.25)
        var changed = false

        if emitting, Self.isSeek(lastTime, currentTime, elapsed) {
            // Reposition future comments without erasing those already crossing the screen.
            cursor = Self.lowerBound(entries, currentTime)
            cooldown = 0
            if !reduced, items.isEmpty, replayQueue.isEmpty {
                var index = cursor - 1
                while index >= 0, replayQueue.count < 6 {
                    let entry = entries[index]
                    if !blocked(entry.text), !replayQueue.contains(where: { $0.content == entry.text }) {
                        replayQueue.append((entry, entry.text))
                    }
                    index -= 1
                }
            }
        }
        if emitting { lastTime = currentTime }

        let before = items.count
        for i in items.indices {
            items[i].age += delta
            if !reduced { items[i].x -= Self.baseSpeed * settings.speed * delta }
        }
        retire(reduced: reduced)
        if items.count != before { changed = true }
        cooldown = max(0, cooldown - delta)

        let layout = DanmakuLayout.make(height: viewport.height, settings: settings, reducedMotion: reduced, bottomInset: viewport.bottomInset)
        func laneFree(_ lane: Int) -> Bool {
            let occupants = items.filter { $0.lane == lane }
            guard let newest = occupants.max(by: { $0.x < $1.x }) else { return true }
            return newest.x + newest.width + Self.laneHeadGap <= viewport.width
        }

        var emitted = 0
        let staleAfter = reduced ? Self.reducedMotionReadSeconds : Self.staleSeconds
        while emitting, emitted < Self.maxEmitPerFrame {
            var entry: DanmakuEntry? = cursor < entries.count ? entries[cursor] : nil
            let timed = entry.map { $0.time <= currentTime } ?? false
            if timed, let e = entry {
                let stale = currentTime - e.time > staleAfter
                let visible = items.contains { $0.entry == e }
                if stale || visible || blocked(e.text) { cursor += 1; continue }
            }
            if cooldown > 0 { break }
            guard let lane = (0..<layout.lanes).first(where: laneFree) else { break }
            if !timed {
                guard delta > 0, !entries.isEmpty else { break }
                // Nearby fresh supply takes priority; only quiet stretches replay retired comments.
                let pendingSoon = max(0, Self.lowerBound(entries, currentTime + 2) - cursor)
                guard let replay = takeReplay(lanes: layout.lanes, pending: pendingSoon, currentTime: currentTime, reduced: reduced),
                      let replayEntry = replay.entry else { break }
                entry = replayEntry
            }
            guard let chosen = entry else { break }
            let text = DanmakuFilter.displayText(chosen.text, count: chosen.count)
            items.append(DanmakuSprite(id: nextId, text: text, content: chosen.text, entry: chosen, color: chosen.color, mode: chosen.mode,
                                       lane: lane, x: reduced ? 12 : viewport.width, y: layout.top + Double(lane) * layout.lineHeight,
                                       width: measure(text, settings.fontSize), age: 0))
            nextId += 1
            cooldown = reduced ? Self.reducedMotionReadSeconds : Self.emitInterval(settings.density)
            if timed { cursor += 1 }
            emitted += 1
            changed = true
        }
        return changed
    }

    static func emitInterval(_ density: DanmakuSettings.Density) -> Double {
        switch density { case .sparse: 0.4; case .normal: 0.15; case .dense: 0.05 }
    }

    /// Only fully departed comments enter the replay queue.
    private mutating func retire(reduced: Bool) {
        var kept: [DanmakuSprite] = []
        for item in items {
            if reduced ? item.age < 6 : item.x + item.width > 0 { kept.append(item); continue }
            if !reduced, !replayQueue.contains(where: { $0.content == item.content }) { replayQueue.append((item.entry, item.content)) }
        }
        items = kept
    }

    private mutating func takeReplay(lanes: Int, pending: Int, currentTime: Double, reduced: Bool) -> (entry: DanmakuEntry?, content: String)? {
        if reduced { return nil }
        let target: Int = switch settings.density { case .sparse: 1; case .normal: 3; case .dense: max(6, lanes * 2) }
        if items.count + pending >= target { return nil }
        guard let index = replayQueue.firstIndex(where: { candidate in
            (candidate.entry.map { $0.time <= currentTime } ?? true) && !blocked(candidate.content)
                && !items.contains { $0.content == candidate.content }
        }) else { return nil }
        return replayQueue.remove(at: index)
    }

    /// The single status line for the danmaku toggle (port of `resolveDanmakuStatus`): a failure
    /// always wins over "no danmaku".
    public static func status(supported: Bool, enabled: Bool, active: Bool, error: String, loading: Bool,
                              notice: String, loaded: Bool, count: Int) -> String {
        if !supported { return "仅红果来源的剧集支持弹幕" }
        if !enabled { return "开启后按视频时间展示时间轴弹幕" }
        if !active { return "播放本集后显示弹幕" }
        if !error.isEmpty { return error }
        if loading { return "正在加载弹幕…" }
        if !notice.isEmpty, count == 0 { return notice }
        if !loaded { return "正在加载弹幕…" }
        if count == 0 { return notice.isEmpty ? "本集暂无弹幕" : notice }
        return "已载入 \(count) 条弹幕" + (notice.isEmpty ? "" : "（\(notice)）")
    }
}
