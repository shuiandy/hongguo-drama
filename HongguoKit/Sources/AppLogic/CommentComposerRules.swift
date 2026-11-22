import Foundation

/// Pure editing and validation rules for the episode comment composer and its built-in emoticon tray.
public enum CommentComposerRules {
    public static let maxLength = 500
    private static let maxTokenCharacters = 16

    public static func normalizedDraft(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func canSubmit(_ raw: String, hasImage: Bool = false, isSubmitting: Bool, hasEpisode: Bool) -> Bool {
        guard hasEpisode, !isSubmitting else { return false }
        let trimmed = normalizedDraft(raw)
        if trimmed.isEmpty { return hasImage }
        return trimmed.count <= maxLength
    }

    public static func appendingEmoticon(_ token: String, to draft: String, limit: Int = maxLength) -> String {
        guard !token.isEmpty else { return draft }
        guard draft.count + token.count <= limit else { return draft }
        return draft + token
    }

    /// Removes one trailing `[表情]` token as a single unit when `draft` ends with a known emoticon
    /// token; otherwise deletes the last character.
    public static func deletingBackward(from draft: String, knownTokens: Set<String>) -> String {
        guard !draft.isEmpty else { return "" }
        if draft.last == "]", !knownTokens.isEmpty {
            var idx = draft.index(before: draft.endIndex)
            var scanned = 0
            while scanned < maxTokenCharacters && idx > draft.startIndex {
                idx = draft.index(before: idx)
                scanned += 1
                let ch = draft[idx]
                if ch == "[" {
                    let candidate = String(draft[idx..<draft.endIndex])
                    if knownTokens.contains(candidate)
                        || knownTokens.contains(candidate.lowercased())
                        || knownTokens.contains(candidate.uppercased()) {
                        return String(draft[..<idx])
                    }
                    break
                }
                if ch == "]" { break }
            }
        }
        return String(draft.dropLast())
    }
}
