import Foundation

/// Your win/loss record against or alongside one player (member or guest).
struct PlayerRecord: Identifiable {
    /// Aggregation key (member uid or `guest:<name>`). Distinct from
    /// `person.id` so the dedup keying stays stable across identity changes.
    let id: String
    /// Real identity for avatar + navigation; guests carry initials only.
    let person: PersonRef
    var wins: Int
    var losses: Int

    var games: Int { wins + losses }
    var winRate: Int { games == 0 ? 0 : Int((Double(wins) / Double(games) * 100).rounded()) }
    var recordLine: String { "\(wins)–\(losses)" }
}

/// Win/loss record for one match format. Stored separately from player records
/// so Statistics can compare singles and doubles without changing rivalries.
struct MatchFormatRecord {
    let format: MatchFormat
    let wins: Int
    let losses: Int

    var matches: Int { wins + losses }
    var winRate: Int { matches == 0 ? 0 : Int((Double(wins) / Double(matches) * 100).rounded()) }
    var recordLine: String { "\(wins)–\(losses)" }
}

/// One meeting in a head-to-head history, for the Rivalry Insights timeline.
struct RivalryGame: Identifiable {
    let id = UUID()
    let won: Bool
    let date: Date
}

/// Your ongoing head-to-head story with one opponent: not just a record, but a
/// current streak and when you last met. This is what makes an opponent a rival.
struct Rivalry: Identifiable {
    let id: String
    /// Real identity for avatar + navigation; guests carry initials only.
    let person: PersonRef
    let wins: Int
    let losses: Int
    /// Positive = you're on a win streak over them, negative = they're on you.
    let streak: Int
    let lastPlayed: Date
    /// Every decided meeting, most-recent first. Powers the Rivalry Insights
    /// timeline (Pro) — see `RivalryInsightsSheet`.
    let log: [RivalryGame]

    var games: Int { wins + losses }
    var winRate: Int { games == 0 ? 0 : Int((Double(wins) / Double(games) * 100).rounded()) }
    var recordLine: String { "\(wins)–\(losses)" }
    var streakLabel: String {
        if streak > 0 { return "You W\(streak)" }
        if streak < 0 { return "Them W\(-streak)" }
        return "Even"
    }
    var leadingYou: Bool { wins >= losses }
    var firstPlayed: Date { log.last?.date ?? lastPlayed }
    /// Longest run of consecutive wins or losses across the whole history,
    /// regardless of who was on it.
    var bestStreak: Int {
        var best = 0, current = 0
        var last: Bool?
        for game in log.reversed() {
            current = (game.won == last) ? current + 1 : 1
            last = game.won
            best = max(best, current)
        }
        return best
    }
}

/// All-time match stats derived from the signed-in user's logged sessions.
struct SessionStats {
    let matches: Int
    let wins: Int
    let losses: Int
    let winRate: Int
    let singles: MatchFormatRecord
    let doubles: MatchFormatRecord
    /// Positive = current win streak, negative = current loss streak, 0 = none.
    let currentStreak: Int
    /// Opponents you've faced, most-played first.
    let opponents: [PlayerRecord]
    /// Partners you've played with, most-played first.
    let partners: [PlayerRecord]
    /// Head-to-head rivalries, most-played first — a superset of `opponents`
    /// with streak + recency, for the Rivals surface.
    let rivalries: [Rivalry]

    /// Consecutive calendar weeks (ending at the current/most-recent week) in
    /// which the user logged at least one session. The retention "streak" — a
    /// separate concept from the win streak above. The current week counts as
    /// in-progress and doesn't break the chain until a full empty week elapses.
    let weeklyStreak: Int
    /// Longest weekly streak ever achieved.
    let longestWeeklyStreak: Int

    init(sessions: [FeedSession], playerID: UUID? = nil) {
        let weekly = Self.weeklyStreaks(from: sessions.map(\.workoutDate))
        weeklyStreak = weekly.current
        longestWeeklyStreak = weekly.longest
        var results: [(won: Bool, date: Date, position: Int, format: MatchFormat)] = []
        var opp: [String: PlayerRecord] = [:]
        var part: [String: PlayerRecord] = [:]
        // Per-opponent match log for streak/recency, keyed the same way as `opp`.
        var oppLog: [String: (identity: PlayerRecord, games: [(won: Bool, date: Date, position: Int)])] = [:]

        for session in sessions {
            let workoutActivities = playerID.map { session.workoutActivities(for: $0) } ?? session.sortedActivities
            for activity in workoutActivities where activity.isMatch {
                // Derive from the score so ties are excluded, not counted as losses.
                guard let result = activity.matchResult, result != .tie else { continue }
                let won = result == .win
                results.append((won, session.workoutDate, activity.position, activity.resolvedMatchFormat))
                for p in activity.opponents {
                    Self.bump(&opp, p, won: won)
                    let key = Self.key(for: p)
                    let identity = opp[key]!
                    oppLog[key, default: (identity, [])].games.append((won, session.workoutDate, activity.position))
                    oppLog[key]!.identity = identity
                }
                for p in activity.partners { Self.bump(&part, p, won: won) }
            }
        }

        matches = results.count
        wins = results.filter(\.won).count
        losses = matches - wins
        winRate = matches == 0 ? 0 : Int((Double(wins) / Double(matches) * 100).rounded())
        singles = Self.formatRecord(.singles, from: results)
        doubles = Self.formatRecord(.doubles, from: results)

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
                id: r.id, person: r.person,
                wins: r.wins, losses: r.losses, streak: h2h,
                lastPlayed: games.first?.date ?? .distantPast,
                log: games.map { RivalryGame(won: $0.won, date: $0.date) }
            )
        }
        .sorted { $0.games != $1.games ? $0.games > $1.games : $0.lastPlayed > $1.lastPlayed }
    }

    private static func key(for p: ActivityParticipant) -> String {
        p.profile?.id.uuidString ?? "guest:\(p.guestName ?? p.id.uuidString)"
    }

    private static func formatRecord(
        _ format: MatchFormat,
        from results: [(won: Bool, date: Date, position: Int, format: MatchFormat)]
    ) -> MatchFormatRecord {
        let matches = results.filter { $0.format == format }
        return MatchFormatRecord(
            format: format,
            wins: matches.filter(\.won).count,
            losses: matches.filter { !$0.won }.count
        )
    }

    /// Win/loss streak label (a performance stat — labeled "Win streak" in UI).
    var streakLabel: String {
        if currentStreak > 0 { return "W\(currentStreak)" }
        if currentStreak < 0 { return "L\(-currentStreak)" }
        return "-"
    }

    /// Consistency streak label, e.g. "6 wk" or "-".
    var weeklyStreakLabel: String {
        weeklyStreak > 0 ? "\(weeklyStreak) wk" : "-"
    }

    /// Weekly play-streak from a list of session dates. Returns the current streak
    /// (consecutive weeks ending at the current or last week) and the longest run.
    static func weeklyStreaks(from dates: [Date]) -> (current: Int, longest: Int) {
        guard !dates.isEmpty else { return (0, 0) }
        var cal = Calendar.current
        cal.firstWeekday = 2 // Monday-based weeks; stable regardless of locale
        func weekStart(_ d: Date) -> Date {
            cal.dateInterval(of: .weekOfYear, for: d)?.start ?? cal.startOfDay(for: d)
        }
        func prevWeek(_ d: Date) -> Date {
            cal.date(byAdding: .weekOfYear, value: -1, to: d) ?? d
        }

        let played = Set(dates.map(weekStart))
        let thisWeek = weekStart(Date())
        let lastWeek = prevWeek(thisWeek)

        // Anchor: start counting from this week if played, else last week (this
        // week is still in progress). If neither, a full empty week elapsed → 0.
        var current = 0
        if played.contains(thisWeek) || played.contains(lastWeek) {
            var cursor = played.contains(thisWeek) ? thisWeek : lastWeek
            while played.contains(cursor) {
                current += 1
                cursor = prevWeek(cursor)
            }
        }

        // Longest: walk all played weeks oldest→newest, counting consecutive runs.
        let sorted = played.sorted()
        var longest = 0, run = 0
        var previous: Date?
        for w in sorted {
            if let p = previous, prevWeek(w) == p { run += 1 } else { run = 1 }
            longest = max(longest, run)
            previous = w
        }
        return (current, max(longest, current))
    }

    private static func bump(_ dict: inout [String: PlayerRecord], _ p: ActivityParticipant, won: Bool) {
        let key = Self.key(for: p)
        var record = dict[key] ?? PlayerRecord(id: key, person: person(for: p), wins: 0, losses: 0)
        if won { record.wins += 1 } else { record.losses += 1 }
        dict[key] = record
    }

    /// Real identity for a participant: a linked profile when present, else a
    /// guest ref (initials only, non-navigable by construction).
    private static func person(for p: ActivityParticipant) -> PersonRef {
        if let profile = p.profile { return PersonRef(participant: profile) }
        return PersonRef(guestName: p.displayName)
    }
}
