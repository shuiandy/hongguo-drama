#if canImport(UIKit)
import HongguoCore
import SwiftUI
import UIKit

/// Display-only danmaku over the video. The core's `DanmakuStage` decides what is on screen and
/// where; this view advances it once per frame and draws the result.
public struct DanmakuLayer: View {
    public init(items: [DanmakuItem], engine: PlayerEngine, settings: DanmakuSettings, bottomInset: Double) {
        self.items = items
        self.engine = engine
        self.settings = settings
        self.bottomInset = bottomInset
    }

    public let items: [DanmakuItem]
    public let engine: PlayerEngine
    public let settings: DanmakuSettings
    public var bottomInset: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var runner = DanmakuRunner()

    public var body: some View {
        TimelineView(.animation(paused: !engine.isPlaying)) { timeline in
            Canvas { context, size in
                runner.tick(now: timeline.date, engine: engine, size: size, settings: settings,
                            reduceMotion: reduceMotion, bottomInset: bottomInset)
                context.opacity = settings.opacity / 100
                context.addFilter(.shadow(color: .black.opacity(0.85), radius: 1.5, x: 0, y: 1))
                for sprite in runner.stage.items {
                    let text = runner.renderedText(for: sprite.text, fontSize: settings.fontSize, colorHex: sprite.color)
                    context.draw(text, at: CGPoint(x: sprite.x, y: sprite.y), anchor: .topLeading)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: items, initial: true) { _, new in runner.load(new) }
        .onChange(of: engine.isPlaying) { wasPlaying, isPlaying in
            if !wasPlaying && isPlaying { runner.resumedPlayback() }
        }
    }
}

/// Holds the stage between frames. A class, so drawing can advance it without a state write.
@MainActor
public final class DanmakuRunner {
    public private(set) var stage = DanmakuStage()
    private var lastFrame: Date?
    private var applied: DanmakuSettings?
    private var cachedText: [String: Text] = [:]
    private var cachedFontSize: CGFloat = 0

    public func resumedPlayback() {
        lastFrame = nil
    }

    public init() {
        stage.measure = { text, fontSize in
            EmoticonCatalog.shared.measureWidth(text, fontSize: fontSize, weight: .bold)
        }
    }

    public func renderedText(for raw: String, fontSize: CGFloat, colorHex: String) -> Text {
        if cachedFontSize != fontSize {
            cachedText.removeAll(keepingCapacity: true)
            cachedFontSize = fontSize
        }
        let key = "\(colorHex)\u{0}\(raw)"
        if let hit = cachedText[key] { return hit }
        let built = EmoticonCatalog.shared.richText(
            raw,
            fontSize: fontSize,
            weight: .bold,
            color: Color(hex: colorHex) ?? .white
        )
        if cachedText.count > 256 { cachedText.removeAll(keepingCapacity: true) }
        cachedText[key] = built
        return built
    }

    public func load(_ items: [DanmakuItem]) {
        stage.reset()
        stage.load(items)
        lastFrame = nil
        cachedText.removeAll(keepingCapacity: true)
    }

    public func tick(now: Date, engine: PlayerEngine, size: CGSize, settings: DanmakuSettings, reduceMotion: Bool, bottomInset: Double) {
        if applied != settings {
            stage.update(settings: settings)
            applied = settings
        }
        let wall = lastFrame.map { now.timeIntervalSince($0) } ?? 0
        lastFrame = now
        let playing = engine.isPlaying
        let rate = engine.isHoldingSpeed ? engine.holdRate : engine.rate
        _ = stage.advance(currentTime: engine.currentTime, elapsed: playing ? wall * Double(rate) : 0,
                          viewport: .init(width: size.width, height: size.height, reducedMotion: reduceMotion, bottomInset: bottomInset),
                          emitting: playing)
    }
}

extension Color {
    /// "#RRGGBB" or "RRGGBB".
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}
#endif
