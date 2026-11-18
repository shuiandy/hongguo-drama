import AppKit
import SwiftUI
import HongguoCore

/// Danmaku for the current episode: fetches comments and runs the core `DanmakuStage` every frame.
@MainActor
@Observable
final class DanmakuModel {
    static let shared = DanmakuModel()

    private(set) var total = 0
    private(set) var isLoading = false
    private(set) var notice: String?

    @ObservationIgnored private(set) var stage = DanmakuStage()
    @ObservationIgnored private var key: String?
    @ObservationIgnored private var lastFrame: Date?
    @ObservationIgnored private var appliedSettings: DanmakuSettings?

    private init() {
        stage.measure = { text, fontSize in
            Double((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .bold)]).width) + 4
        }
    }

    func load(seriesId: String, vid: String, fresh: Bool = false) async {
        let newKey = "\(seriesId):\(vid)"
        guard fresh || newKey != key else { return }
        key = newKey
        stage.reset()
        stage.load([])
        total = 0
        notice = nil
        isLoading = true
        let result = await DanmakuService.shared.fetch(seriesId: seriesId, vid: vid, fresh: fresh)
        guard key == newKey else { return }
        isLoading = false
        stage.load(result.items)
        total = result.total
        notice = result.success ? (result.notice.isEmpty ? nil : result.notice) : result.error
    }

    func clear() {
        key = nil
        stage.reset()
        stage.load([])
        total = 0
        notice = nil
    }

    /// Advances the stage to `now`. Called from the canvas on every display frame.
    func tick(now: Date, currentTime: Double, rate: Float, playing: Bool, size: CGSize, settings: DanmakuSettings, bottomInset: Double) {
        if appliedSettings != settings {
            stage.update(settings: settings)
            appliedSettings = settings
        }
        let wall = lastFrame.map { now.timeIntervalSince($0) } ?? 0
        lastFrame = now
        let elapsed = playing ? wall * Double(rate) : 0
        stage.advance(currentTime: currentTime, elapsed: elapsed,
                      viewport: .init(width: size.width, height: size.height,
                                      reducedMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                                      bottomInset: bottomInset),
                      emitting: playing)
    }
}

/// Draws the danmaku sprites over the video.
struct DanmakuOverlay: View {
    let controller: PlayerController
    var bottomInset: Double = 120

    private var settings: DanmakuSettings { AppModel.shared.settings.danmaku }
    private var currentVid: String? {
        guard let list = controller.episodes, controller.index > 0, controller.index <= list.episodes.count else { return nil }
        return list.episodes[controller.index - 1].vid
    }

    var body: some View {
        let model = DanmakuModel.shared
        let settings = settings
        TimelineView(.animation(paused: !settings.enabled || !controller.isPlaying)) { timeline in
            Canvas { context, size in
                model.tick(now: timeline.date, currentTime: controller.currentTime, rate: controller.rate,
                           playing: controller.isPlaying, size: size, settings: settings, bottomInset: bottomInset)
                guard settings.enabled else { return }
                context.opacity = settings.opacity / 100
                context.addFilter(.shadow(color: .black.opacity(0.85), radius: 1.5, x: 0, y: 1))
                for sprite in model.stage.items {
                    let text = Text(sprite.text)
                        .font(.system(size: settings.fontSize, weight: .bold))
                        .foregroundColor(Color(hex: sprite.color) ?? .white)
                    context.draw(text, at: CGPoint(x: sprite.x, y: sprite.y), anchor: .topLeading)
                }
            }
        }
        .allowsHitTesting(false)
        .task(id: "\(controller.episodes?.seriesId ?? ""):\(currentVid ?? "")") {
            guard let seriesId = controller.episodes?.seriesId, let vid = currentVid else { model.clear(); return }
            await model.load(seriesId: seriesId, vid: vid)
        }
    }
}

/// Danmaku settings popover, bound to `AppModel.settings.danmaku`.
struct DanmakuSettingsPanel: View {
    @Bindable private var app = AppModel.shared
    private let model = DanmakuModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("弹幕").font(.system(size: 15, weight: .bold))
                Spacer()
                Toggle("显示弹幕", isOn: $app.settings.danmaku.enabled).toggleStyle(.switch).labelsHidden().tint(.hongguoRed)
            }
            Text(statusLine).font(.system(size: 11)).foregroundStyle(.secondary)
            slider("不透明度", value: $app.settings.danmaku.opacity, range: 20...100, format: { "\(Int($0))%" })
            slider("字号", value: $app.settings.danmaku.fontSize, range: 16...32, format: { "\(Int($0))" })
            slider("速度", value: $app.settings.danmaku.speed, range: 0.5...2, format: { String(format: "%.1fx", $0) })
            row("显示区域") {
                Picker("", selection: $app.settings.danmaku.area) {
                    Text("1/4 屏").tag(DanmakuSettings.Area.quarter)
                    Text("半屏").tag(DanmakuSettings.Area.half)
                    Text("全屏").tag(DanmakuSettings.Area.full)
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            row("密度") {
                Picker("", selection: $app.settings.danmaku.density) {
                    Text("稀疏").tag(DanmakuSettings.Density.sparse)
                    Text("标准").tag(DanmakuSettings.Density.normal)
                    Text("密集").tag(DanmakuSettings.Density.dense)
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            Toggle("过滤敏感词", isOn: $app.settings.danmaku.sensitiveFilter)
            VStack(alignment: .leading, spacing: 4) {
                Text("屏蔽词（用逗号或换行分隔）").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("例如：剧透，广告", text: $app.settings.danmaku.blockedWords, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private var statusLine: String {
        if model.isLoading { return "正在加载本集弹幕…" }
        if let notice = model.notice { return notice }
        return model.total > 0 ? "本集共 \(model.total) 条弹幕" : "本集暂无弹幕"
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: @escaping (Double) -> String) -> some View {
        row(title) {
            HStack(spacing: 8) {
                Slider(value: value, in: range).controlSize(.small)
                Text(format(value.wrappedValue)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
            }
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 12)).frame(width: 56, alignment: .leading)
            content()
        }
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
