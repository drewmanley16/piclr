import Foundation

// MARK: - Live game score model (shared iOS ⇄ watchOS)
//
// Compiled into BOTH the iOS app and the watch target (see project.yml
// `sources`). Dependency-free by design — no SwiftUI, no Supabase — so it
// round-trips cleanly over WatchConnectivity and persists on both devices.
//
// Score is derived from a *log of points* rather than two counters. That gives
// us free undo, correct serve rotation later, and is the exact hook a future
// motion-detection layer uses (inject a `PointEvent(source: .motion)` as a
// suggestion the user confirms — see the plan's "Forward-compat" section).

/// Which side of a match. `us` = the scorekeeper's team, `them` = opponents.
public enum Side: String, Codable, Hashable, Sendable {
    case us
    case them

    public var opposite: Side { self == .us ? .them : .us }
}

/// How a point entered the log. `.manual` today; `.motion` is reserved for a
/// future CoreMotion/ML layer that suggests points for confirmation.
public enum PointSource: String, Codable, Hashable, Sendable {
    case manual
    case motion
}

/// A single rally outcome. The ordered list of these *is* the score.
public struct PointEvent: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var side: Side
    public var at: Date
    public var source: PointSource

    public init(id: UUID = UUID(), side: Side, at: Date = Date(), source: PointSource = .manual) {
        self.id = id
        self.side = side
        self.at = at
        self.source = source
    }
}

/// One in-progress game. Value type so it survives WCSession transport and disk
/// persistence unchanged. A finished game converts into a match `DraftActivity`
/// on the phone (US → team score, THEM → opponent score).
public struct LiveMatchScore: Codable, Hashable, Sendable {
    public var id: UUID
    /// Full ordered point log → derive score, enable undo, drive serve rotation.
    public var points: [PointEvent]
    /// Serve indicator (manual toggle in MVP; auto-rotation is a later setting).
    public var serving: Side
    /// Winning score: 11 / 15 / 21.
    public var target: Int
    /// Whether a 2-point margin is required to win.
    public var winByTwo: Bool
    public var startedAt: Date
    /// Monotonic version stamp for last-writer-wins reconciliation over WC.
    public var seq: Int

    public init(
        id: UUID = UUID(),
        points: [PointEvent] = [],
        serving: Side = .us,
        target: Int = 11,
        winByTwo: Bool = true,
        startedAt: Date = Date(),
        seq: Int = 0
    ) {
        self.id = id
        self.points = points
        self.serving = serving
        self.target = target
        self.winByTwo = winByTwo
        self.startedAt = startedAt
        self.seq = seq
    }

    // MARK: Derived score

    public var us: Int { points.reduce(0) { $0 + ($1.side == .us ? 1 : 0) } }
    public var them: Int { points.reduce(0) { $0 + ($1.side == .them ? 1 : 0) } }

    public func score(for side: Side) -> Int { side == .us ? us : them }

    /// True once one side has reached `target` with the required margin.
    public var isComplete: Bool { winner != nil }

    /// The winning side, or nil while the game is still live.
    public var winner: Side? {
        let (u, t) = (us, them)
        let lead = abs(u - t)
        let high = max(u, t)
        guard high >= target else { return nil }
        guard !winByTwo || lead >= 2 else { return nil }
        return u > t ? .us : .them
    }

    /// True when the next point for `side` would win the game (game point).
    public func isGamePoint(for side: Side) -> Bool {
        var hypothetical = self
        hypothetical.points.append(PointEvent(side: side))
        return hypothetical.winner == side
    }

    // MARK: Mutation (bumps `seq` so the counterpart adopts the newer snapshot)

    /// Award a rally to `side`. No-op once the game is complete.
    public mutating func award(_ side: Side, source: PointSource = .manual) {
        guard !isComplete else { return }
        points.append(PointEvent(side: side, source: source))
        seq += 1
    }

    /// Remove the most recent point (undo). No-op on an empty log.
    public mutating func undo() {
        guard !points.isEmpty else { return }
        points.removeLast()
        seq += 1
    }

    /// Flip the serve indicator.
    public mutating func toggleServe() {
        serving = serving.opposite
        seq += 1
    }
}
