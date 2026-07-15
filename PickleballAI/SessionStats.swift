import Foundation

/// Your win/loss record against or alongside one player (member or guest).
struct PlayerRecord: Identifiable {
    let id: String
    let name: String
    let handle: String?
    let avatarInitials: String
    var wins: Int
    var losses: Int

    var games: Int { wins + losses }
    var winRate: Int { games == 0 ? 0 : Int((Double(wins) / Double(games) * 100).rounded()) }
    var recordLine: String { "\(wins)–\(losses)" }
}

/// Your ongoing head-to-head story with one opponent: not just a record, but a
/// current streak and when you last met. This is what makes an opponent a rival.
struct Rivalry: Identifiable {
    let id: String
    let name: String
    let handle: String?
    let avatarInitials: String
    let wins: Int
    let losses: Int
    /// Positive = you're on a win streak over them, negative = they're on you.
    let streak: Int
    let lastPlayed: Date

    var games: Int { wins + losses }
    var winRate: Int { games == 0 ? 0 : Int((Double(wins) / Double(games) * 100).rounded()) }
    var recordLine: String { "\(wins)–\(losses)" }
    var streakLabel: String {
        if streak > 0 { return "You W\(streak)" }
        if streak < 0 { return "Them W\(-streak)" }
        return "Even"
    }
    var leadingYou: Bool { wins >= losses }
}

/// All-time match stats derived from the signed-in user's logged sessions.
struct SessionStats {
    let matches: Int
    let wins: Int
    let losses: Int
    let winRate: Int
    /// Positive = current win streak, negative = current loss streak, 0 = none.
    let currentStreak: Int
    /// Opponents you've faced, most-played first.
    let opponents: [PlayerRecord]
    /// Partners you've played with, most-played first.
    let partners: [PlayerRecord]
    /// Head-to-head rivalries, most-played first — a superset of `opponents`
    /// with streak + recency, for the Rivals surface.
    let rivalries: [Rivalry]

    init(sessions: [FeedSession]) {
        var results: [(won: Bool, date: Date, position: Int)] = []
        var opp: [String: PlayerRecord] = [:]
        var part: [String: PlayerRecord] = [:]
        // Per-opponent match log for streak/recency, keyed the same way as `opp`.
        var oppLog: [String: (identity: PlayerRecord, games: [(won: Bool, date: Date, position: Int)])] = [:]

        for session in sessions {
            for activity in session.sortedActivities where activity.isMatch {
                guard let won = activity.won else { continue }
                results.append((won, session.date, activity.position))
                for p in activity.opponents {
                    Self.bump(&opp, p, won: won)
                    let key = Self.key(for: p)
                    let identity = opp[key]!
                    oppLog[key, default: (identity, [])].games.append((won, session.date, activity.position))
                    oppLog[key]!.identity = identity
                }
                for p in activity.partners { Self.bump(&part, p, won: won) }
            }
        }

        matches = results.count
        wins = results.filter(\.won).count
        losses = matches - wins
        winRate = matches == 0 ? 0 : Int((Double(wins) / Double(matches) * 100).rounded())

        // Streak: walk matches newest-first, counting consecutive same results.
        let ordered = results.sorted {
            $0.date != $1.date ? $0.date > $1.date : $0.position > $1.position
        }
        var streak = 0
        if let latest = ordered.first?.won {
            for r in ordered {
                if r.won == latest { streak += 1 } else { break }
            }
            if !latest { streak = -streak }
        }
        currentStreak = streak

        opponents = opp.values.sorted { $0.games != $1.games ? $0.games > $1.games : $0.wins > $1.wins }
        partners = part.values.sorted { $0.games != $1.games ? $0.games > $1.games : $0.wins > $1.wins }

        rivalries = oppLog.values.map { entry in
            let games = entry.games.sorted {
                $0.date != $1.date ? $0.date > $1.date : $0.position > $1.position
            }
            var h2h = 0
            if let latest = games.first?.won {
                for g in games {
                    if g.won == latest { h2h += 1 } else { break }
                }
                if !latest { h2h = -h2h }
            }
            let r = entry.identity
            return Rivalry(
                id: r.id, name: r.name, handle: r.handle, avatarInitials: r.avatarInitials,
                wins: r.wins, losses: r.losses, streak: h2h,
                lastPlayed: games.first?.date ?? .distantPast
            )
        }
        .sorted { $0.games != $1.games ? $0.games > $1.games : $0.lastPlayed > $1.lastPlayed }
    }

    private static func key(for p: ActivityParticipant) -> String {
        p.profile?.id.uuidString ?? "guest:\(p.guestName ?? p.id.uuidString)"
    }

    var streakLabel: String {
        if currentStreak > 0 { return "W\(currentStreak)" }
        if currentStreak < 0 { return "L\(-currentStreak)" }
        return "—"
    }

    private static func bump(_ dict: inout [String: PlayerRecord], _ p: ActivityParticipant, won: Bool) {
        let key = p.profile?.id.uuidString ?? "guest:\(p.guestName ?? p.id.uuidString)"
        var record = dict[key] ?? PlayerRecord(
            id: key,
            name: p.displayName,
            handle: p.handle,
            avatarInitials: initials(for: p),
            wins: 0,
            losses: 0
        )
        if won { record.wins += 1 } else { record.losses += 1 }
        dict[key] = record
    }

    private static func initials(for p: ActivityParticipant) -> String {
        if let a = p.profile?.avatarInitials, !a.isEmpty { return a }
        let letters = p.displayName.split(separator: " ").prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}
