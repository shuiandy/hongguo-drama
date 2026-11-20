import AppKit
import SwiftUI

/// The built-in Hongguo emoticon pack (Resources/Emoticons, copied into the app by build-app.sh):
/// `map.json` maps each text code such as "[666]" to an image file in the same folder. Comments,
/// reviews and danmaku show the image in place of the code; unknown codes stay as text.
@MainActor
enum Emoticons {
    /// Longest code in the pack is well under this; keeps the scan cheap on long comments.
    private static let maxCodeLength = 16

    static let directory: URL? = {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent("Emoticons")) }
        // `swift run` from the package: the folder next to Sources.
        candidates.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Resources/Emoticons").standardizedFileURL)
        return candidates.first { fm.fileExists(atPath: $0.appendingPathComponent("map.json").path) }
    }()

    /// Code -> file name. Only plain file names inside the folder are accepted.
    static let map: [String: String] = {
        guard let directory,
              let data = try? Data(contentsOf: directory.appendingPathComponent("map.json")),
              let raw = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return raw.filter { code, file in
            code.hasPrefix("[") && code.hasSuffix("]") && code.count <= maxCodeLength
                && !file.contains("/") && !file.hasPrefix(".")
                && ["png", "webp"].contains((file as NSString).pathExtension.lowercased())
        }
    }()

    private static var images: [String: NSImage] = [:]

    static func image(for code: String) -> NSImage? {
        guard let file = map[code], let directory else { return nil }
        if let cached = images[file] { return cached }
        guard let image = NSImage(contentsOf: directory.appendingPathComponent(file)) else { return nil }
        images[file] = image
        return image
    }

    enum Piece: Equatable {
        case text(String)
        case emoticon(String)
    }

    /// Splits text into plain runs and known emoticon codes.
    static func pieces(_ text: String) -> [Piece] {
        guard text.contains("["), !map.isEmpty else { return [.text(text)] }
        var result: [Piece] = []
        var plain = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "[",
               let close = text[index...].prefix(maxCodeLength).firstIndex(of: "]") {
                let code = String(text[index...close])
                if map[code] != nil {
                    if !plain.isEmpty { result.append(.text(plain)); plain = "" }
                    result.append(.emoticon(code))
                    index = text.index(after: close)
                    continue
                }
            }
            plain.append(text[index])
            index = text.index(after: index)
        }
        if !plain.isEmpty { result.append(.text(plain)) }
        return result
    }

    /// The text with emoticon images inline, each about the height of the font.
    static func text(_ string: String, size: CGFloat) -> Text {
        let parts = pieces(string)
        if parts == [.text(string)] { return Text(verbatim: string) }
        var result = Text(verbatim: "")
        for part in parts {
            switch part {
            case .text(let run):
                result = Text("\(result)\(Text(verbatim: run))")
            case .emoticon(let code):
                if let image = sized(code, size: size) {
                    result = Text("\(result)\(Text(Image(nsImage: image)).baselineOffset(-size * 0.18))")
                } else {
                    result = Text("\(result)\(Text(verbatim: code))")
                }
            }
        }
        return result
    }

    private static var sizedImages: [String: NSImage] = [:]

    private static func sized(_ code: String, size: CGFloat) -> NSImage? {
        let edge = (size * 1.25).rounded()
        let key = "\(code)@\(edge)"
        if let cached = sizedImages[key] { return cached }
        guard let source = image(for: code), let copy = source.copy() as? NSImage else { return nil }
        let aspect = source.size.height > 0 ? source.size.width / source.size.height : 1
        copy.size = NSSize(width: edge * aspect, height: edge)
        sizedImages[key] = copy
        return copy
    }
}

/// A comment or review body with emoticons drawn inline.
struct EmoticonText: View {
    let string: String
    var size: CGFloat = 13

    init(_ string: String, size: CGFloat = 13) {
        self.string = string
        self.size = size
    }

    var body: some View {
        Emoticons.text(string, size: size).font(.system(size: size))
    }
}
