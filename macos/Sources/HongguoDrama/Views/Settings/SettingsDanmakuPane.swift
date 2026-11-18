import SwiftUI
import HongguoCore

/// 弹幕: the same settings as the player's danmaku popover, with a live preview.
struct SettingsDanmakuPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section { preview.listRowInsets(EdgeInsets()) }

            Section("显示") {
                Toggle(isOn: $model.settings.danmaku.enabled) {
                    SettingLabel("显示弹幕", note: "播放器里按 B 或点弹幕按钮也能随时开关。")
                }
                LabeledContent {
                    Picker("弹幕来源", selection: $model.settings.danmaku.source) {
                        Text("自动").tag(DanmakuSettings.Source.auto)
                        Text("时间轴弹幕").tag(DanmakuSettings.Source.official)
                        Text("本集评论").tag(DanmakuSettings.Source.comments)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                } label: {
                    SettingLabel("弹幕来源", note: "自动：优先时间轴弹幕，本集没有或加载失败时改用本集公开评论。")
                }
                slider("不透明度", value: $model.settings.danmaku.opacity, range: 20...100, step: 5) { "\(Int($0))%" }
                slider("字号", value: $model.settings.danmaku.fontSize, range: 16...32, step: 1) { "\(Int($0)) pt" }
                slider("速度", value: $model.settings.danmaku.speed, range: 0.5...2, step: 0.1) { String(format: "%.1fx", $0) }
                LabeledContent("显示区域") {
                    Picker("显示区域", selection: $model.settings.danmaku.area) {
                        Text("1/4 屏").tag(DanmakuSettings.Area.quarter)
                        Text("半屏").tag(DanmakuSettings.Area.half)
                        Text("全屏").tag(DanmakuSettings.Area.full)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                LabeledContent("密度") {
                    Picker("密度", selection: $model.settings.danmaku.density) {
                        Text("稀疏").tag(DanmakuSettings.Density.sparse)
                        Text("标准").tag(DanmakuSettings.Density.normal)
                        Text("密集").tag(DanmakuSettings.Density.dense)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
            .disabled(!model.settings.danmaku.enabled)

            Section("屏蔽") {
                Toggle(isOn: $model.settings.danmaku.sensitiveFilter) {
                    SettingLabel("屏蔽敏感词", note: "使用内置词表过滤。")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("自定义屏蔽词")
                    TextField("例如：剧透，广告", text: $model.settings.danmaku.blockedWords, axis: .vertical)
                        .lineLimit(3...6)
                        .textFieldStyle(.roundedBorder)
                    Text("用换行、逗号或分号分隔。").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double,
                        format: @escaping (Double) -> String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: value, in: range, step: step).frame(width: 200).labelsHidden()
                Text(format(value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
            }
        }
    }

    /// Static sample lines drawn with the current opacity, size and area.
    private var preview: some View {
        let d = model.settings.danmaku
        let areaFraction: CGFloat = d.area == .quarter ? 0.25 : d.area == .half ? 0.5 : 1
        let samples: [(String, CGFloat, CGFloat, Color)] = [
            ("太奶奶太飒了", 0.58, 0.12, .white), ("前方高能", 0.14, 0.42, .white),
            ("哈哈哈哈哈", 0.4, 0.72, Color.hongguoGold), ("这集好看", 0.75, 0.9, .white),
        ]
        return GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(red: 0.35, green: 0.12, blue: 0.3), Color(red: 0.1, green: 0.1, blue: 0.25)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Rectangle().fill(.white.opacity(0.06))
                    .frame(height: proxy.size.height * areaFraction)
                if d.enabled {
                    ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                        if sample.2 <= areaFraction {
                            Text(sample.0)
                                .font(.system(size: d.fontSize * 0.8, weight: .semibold))
                                .foregroundStyle(sample.3)
                                .shadow(color: .black.opacity(0.8), radius: 1, y: 1)
                                .opacity(d.opacity / 100)
                                .position(x: proxy.size.width * sample.1, y: max(14, proxy.size.height * sample.2 - 8))
                        }
                    }
                }
                Text(d.enabled ? "预览" : "弹幕已关闭")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 9).frame(height: 22)
                    .glassSurface(.clear, in: Capsule())
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .frame(height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
