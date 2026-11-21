import Foundation

public enum EmoticonSegment: Equatable, Sendable {
    case text(String)
    case emoticon(token: String, filename: String)
}

/// Splits danmaku/comment strings containing bracketed tokens like `[笑哭]` or `[捂脸]`
/// into alternating plain-text and matched emoticon segments.
public enum EmoticonParser {
    private static let maxTokenCharacters = 16

    public static func parse(_ input: String, mapping: [String: String]) -> [EmoticonSegment] {
        guard !input.isEmpty else { return [] }
        guard !mapping.isEmpty, input.contains("[") else {
            return [.text(input)]
        }

        var segments: [EmoticonSegment] = []
        var textStart = input.startIndex
        var cursor = input.startIndex

        func flushText(upTo end: String.Index) {
            guard textStart < end else { return }
            let slice = String(input[textStart..<end])
            if case .text(let prev)? = segments.last {
                segments[segments.count - 1] = .text(prev + slice)
            } else {
                segments.append(.text(slice))
            }
        }

        while cursor < input.endIndex {
            if input[cursor] == "[" {
                var probe = input.index(after: cursor)
                var steps = 0
                var matchedEnd: String.Index?
                var matchedFile: String?

                while probe < input.endIndex && steps < maxTokenCharacters {
                    let ch = input[probe]
                    if ch == "[" {
                        // Nested '[': abandon outer bracket and let outer loop try this inner '['.
                        break
                    }
                    if ch == "]" {
                        let end = input.index(after: probe)
                        let token = String(input[cursor..<end])
                        if let file = mapping[token] ?? mapping[token.lowercased()] ?? mapping[token.uppercased()] {
                            matchedEnd = end
                            matchedFile = file
                        }
                        break
                    }
                    probe = input.index(after: probe)
                    steps += 1
                }

                if let end = matchedEnd, let file = matchedFile {
                    flushText(upTo: cursor)
                    segments.append(.emoticon(token: String(input[cursor..<end]), filename: file))
                    cursor = end
                    textStart = end
                    continue
                }
            }
            cursor = input.index(after: cursor)
        }

        flushText(upTo: input.endIndex)
        return segments
    }
}
