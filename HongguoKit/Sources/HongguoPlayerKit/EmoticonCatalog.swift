#if canImport(UIKit)
import AppLogic
import SwiftUI
import UIKit

public struct EmoticonItem: Identifiable, Hashable, Sendable {
    public init(token: String, filename: String) {
        self.token = token
        self.filename = filename
    }

    public let token: String
    public let filename: String
    public var id: String { token }
}

/// Loads and caches the bundled Hongguo/ByteDance emoticon images (`Emoticons.bundle`, a resource of this package)
/// and converts bracketed tokens like `[笑哭]` / `[捂脸]` into inline SwiftUI `Text`.
public final class EmoticonCatalog: @unchecked Sendable {
    public static let shared = EmoticonCatalog()

    private let bundleURL: URL?
    private let mapping: [String: String]
    public let knownTokens: Set<String>
    /// Built-in emoticons for the composer tray: official 53 Hongguo emojis (`emoji_dr_1`..`53`)
    /// first in official order, followed by the remaining deduplicated built-in emoticons.
    public let pickerItems: [EmoticonItem]
    private let rawCache = NSCache<NSString, UIImage>()
    private let scaledCache = NSCache<NSString, UIImage>()

    private init() {
        rawCache.countLimit = 200
        scaledCache.countLimit = 400
        let url = Bundle.module.url(forResource: "Emoticons", withExtension: "bundle")
        self.bundleURL = url
        let dict: [String: String]
        if let url,
           let data = try? Data(contentsOf: url.appendingPathComponent("map.json")),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            dict = decoded
        } else {
            dict = [:]
        }
        self.mapping = dict
        self.knownTokens = Set(dict.keys)
        self.pickerItems = Self.buildPickerItems(from: dict)
    }

    private static func buildPickerItems(from dict: [String: String]) -> [EmoticonItem] {
        var primary: [(Int, EmoticonItem)] = []
        var secondary: [EmoticonItem] = []
        var seenFiles = Set<String>()

        for (token, filename) in dict.sorted(by: { $0.key < $1.key }) {
            if filename.hasPrefix("emoji_dr_"), filename.hasSuffix(".webp"),
               let index = Int(filename.dropFirst("emoji_dr_".count).dropLast(".webp".count)) {
                guard seenFiles.insert(filename).inserted else { continue }
                primary.append((index, EmoticonItem(token: token, filename: filename)))
            }
        }
        primary.sort { $0.0 < $1.0 }

        for (token, filename) in dict.sorted(by: { $0.key < $1.key }) {
            guard seenFiles.insert(filename).inserted else { continue }
            secondary.append(EmoticonItem(token: token, filename: filename))
        }
        return primary.map(\.1) + secondary
    }

    /// Cached emoticon image for the picker grid.
    public func pickerIcon(filename: String) -> UIImage? {
        rawIcon(filename: filename)
    }

    /// Parses `raw` into text and emoticon segments.
    public func segments(for raw: String) -> [EmoticonSegment] {
        EmoticonParser.parse(raw, mapping: mapping)
    }

    /// Measures pixel width of a danmaku string with emoticons replaced by square inline icons.
    public func measureWidth(_ raw: String, fontSize: CGFloat, weight: UIFont.Weight = .bold) -> Double {
        let segs = segments(for: raw)
        let font = UIFont.systemFont(ofSize: fontSize, weight: weight)
        let iconSide = iconSideLength(for: fontSize)
        var width: CGFloat = 0
        for seg in segs {
            switch seg {
            case .text(let str):
                width += (str as NSString).size(withAttributes: [.font: font]).width
            case .emoticon:
                width += iconSide + 2
            }
        }
        return Double(width) + 4
    }

    /// Builds a SwiftUI `Text` view with `[表情]` tokens rendered as crisp inline icons.
    public func richText(_ raw: String, fontSize: CGFloat, weight: Font.Weight = .regular, color: Color? = nil) -> Text {
        let segs = segments(for: raw)
        let font = Font.system(size: fontSize, weight: weight)
        let baseline = -fontSize * 0.18
        if segs.isEmpty {
            return Text("")
        }
        if segs.count == 1, case .text(let only) = segs[0] {
            var t = Text(only).font(font)
            if let color { t = t.foregroundColor(color) }
            return t
        }
        var combined = Text("")
        for seg in segs {
            switch seg {
            case .text(let str):
                var part = Text(str).font(font)
                if let color { part = part.foregroundColor(color) }
                combined = combined + part
            case .emoticon(let token, let filename):
                if let icon = scaledIcon(filename: filename, fontSize: fontSize) {
                    combined = combined + Text(Image(uiImage: icon)).baselineOffset(baseline)
                } else {
                    var fallback = Text(token).font(font)
                    if let color { fallback = fallback.foregroundColor(color) }
                    combined = combined + fallback
                }
            }
        }
        return combined
    }

    private func iconSideLength(for fontSize: CGFloat) -> CGFloat {
        (fontSize * 1.25).rounded()
    }

    private func rawIcon(filename: String) -> UIImage? {
        let key = filename as NSString
        if let hit = rawCache.object(forKey: key) { return hit }
        guard let url = bundleURL?.appendingPathComponent(filename),
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else {
            return nil
        }
        rawCache.setObject(image, forKey: key)
        return image
    }

    private func scaledIcon(filename: String, fontSize: CGFloat) -> UIImage? {
        let side = iconSideLength(for: fontSize)
        let cacheKey = "\(filename)@\(Int(side))" as NSString
        if let hit = scaledCache.object(forKey: cacheKey) { return hit }
        guard let source = rawIcon(filename: filename) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3.0
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let resized = renderer.image { _ in
            source.draw(in: CGRect(origin: .zero, size: CGSize(width: side, height: side)))
        }
        scaledCache.setObject(resized, forKey: cacheKey)
        return resized
    }
}
#endif
