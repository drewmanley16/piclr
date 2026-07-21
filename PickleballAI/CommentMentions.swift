import SwiftUI

// MARK: - @mentions in comments (client helpers)

/// Someone who can be @mentioned from the composer — the session's tagged
/// players plus the commenter's follows. Wraps `ParticipantProfile` so the
/// autocomplete row can reuse `ProfileAvatar(participant:)`.
struct MentionCandidate: Identifiable, Hashable {
    let profile: ParticipantProfile
    var id: UUID { profile.id }
    var username: String { profile.username }
    var displayName: String { profile.displayName }

    init(_ profile: ParticipantProfile) { self.profile = profile }
    init(_ profile: Profile) { self.profile = ParticipantProfile(profile: profile) }
}

enum CommentMentions {
    /// `@handle` tokens. Usernames are lowercase `[a-z0-9_.]`; match liberally and
    /// lowercase for comparison.
    private static let regex = try! NSRegularExpression(pattern: "@([A-Za-z0-9_.]+)")

    private static func isHandleChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_" || c == "."
    }

    /// The `@handle` the user is currently typing at the caret (assumed at end of
    /// `text`): an `@` at a word boundary followed only by handle characters.
    /// Returns the replaceable range and the lowercased prefix typed so far.
    static func activeQuery(in text: String) -> (range: Range<String.Index>, prefix: String)? {
        guard let atIndex = text.lastIndex(of: "@") else { return nil }
        if atIndex > text.startIndex {
            let before = text[text.index(before: atIndex)]
            guard before.isWhitespace || before.isNewline else { return nil }
        }
        let after = text[text.index(after: atIndex)...]
        guard after.allSatisfy(isHandleChar) else { return nil }  // token still being typed
        return (atIndex..<text.endIndex, after.lowercased())
    }

    /// Replace the active `@query` with the chosen handle plus a trailing space.
    static func insert(_ username: String, into text: String) -> String {
        guard let (range, _) = activeQuery(in: text) else { return text }
        return text.replacingCharacters(in: range, with: "@\(username) ")
    }

    /// Render a comment body, accenting + linking every `@handle` that resolves
    /// to a known user. Links use a `pmention://<uuid>` scheme handled by the
    /// comments screen's `openURL` action.
    static func attributed(_ body: String, resolver: [String: UUID], accent: Color) -> AttributedString {
        var result = AttributedString()
        let ns = body as NSString
        var cursor = 0
        for match in regex.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            let handle = ns.substring(with: match.range(at: 1)).lowercased()
            guard let uid = resolver[handle] else { continue }
            if match.range.location > cursor {
                result += AttributedString(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            }
            var mention = AttributedString(ns.substring(with: match.range))
            mention.foregroundColor = accent
            mention.font = .subheadline.weight(.semibold)
            mention.link = URL(string: "pmention://\(uid.uuidString)")
            result += mention
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            result += AttributedString(ns.substring(from: cursor))
        }
        return result
    }
}
