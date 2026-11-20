import Foundation

/// Text helpers for web pages (share links, the overseas and custom sources). Hongguo's own website
/// is not read for data. Only JSON literals are parsed; no script from a page is ever executed.
public enum HTMLData {
    /// Decodes common HTML entities.
    public static func decodeEntities(_ value: String) -> String {
        guard value.contains("&") else { return value }
        let regex = try! NSRegularExpression(pattern: "&(#x[0-9a-fA-F]+|#\\d+|quot|apos|amp|lt|gt);")
        let ns = value as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: value, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let key = ns.substring(with: match.range(at: 1))
            var replacement = ns.substring(with: match.range)
            switch key.lowercased() {
            case "quot": replacement = "\""
            case "apos": replacement = "'"
            case "amp": replacement = "&"
            case "lt": replacement = "<"
            case "gt": replacement = ">"
            default:
                let code: UInt32? = key.lowercased().hasPrefix("#x") ? UInt32(key.dropFirst(2), radix: 16) : UInt32(key.dropFirst())
                if let code, code > 0, let scalar = Unicode.Scalar(code) { replacement = String(Character(scalar)) }
            }
            result += replacement
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    /// Unescapes `/`, `\/`, `&` and `&amp;` in embedded URLs.
    public static func cleanURL(_ value: String) -> String {
        value.replacingOccurrences(of: "\\u002F", with: "/", options: .caseInsensitive)
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\u0026", with: "&", options: .caseInsensitive)
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Only http(s) image URLs are rendered.
    public static func safeCover(_ value: String?) -> String {
        let url = cleanURL(value ?? "")
        let lower = url.lowercased()
        return lower.hasPrefix("https://") || lower.hasPrefix("http://") ? url : ""
    }

    public static func stripTags(_ value: String) -> String {
        let stripped = value.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
        return decodeEntities(stripped).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// All `<script ...>body</script>` blocks as (attributes, body).
    public static func scripts(_ html: String) -> [(attributes: String, body: String)] {
        let regex = try! NSRegularExpression(pattern: "<script\\b([^>]*)>([\\s\\S]*?)</script\\s*>", options: [.caseInsensitive])
        let ns = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).map {
            (ns.substring(with: $0.range(at: 1)), ns.substring(with: $0.range(at: 2)))
        }
    }

    static func firstMatch(_ pattern: String, in text: String, options: NSRegularExpression.Options = [.caseInsensitive]) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<match.numberOfRanges).map {
            let range = match.range(at: $0)
            return range.location == NSNotFound ? "" : ns.substring(with: range)
        }
    }

    static func allMatches(_ pattern: String, in text: String, options: NSRegularExpression.Options = [.caseInsensitive]) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            (0..<match.numberOfRanges).map {
                let range = match.range(at: $0)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
        }
    }
}

extension String {
    var isDigitsOnly: Bool { !isEmpty && allSatisfy { $0.isASCII && $0.isNumber } }
    func matchesDigits(min: Int, max: Int) -> Bool { isDigitsOnly && count >= min && count <= max }
}
