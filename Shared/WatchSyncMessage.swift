import Foundation

// MARK: - WatchConnectivity payload contract (shared iOS ⇄ watchOS)
//
// Compiled into BOTH targets. Everything the two devices say to each other is
// one of these `WatchSyncMessage` cases, encoded to a `[String: Any]` dictionary
// (WCSession's native transport) via `payload` / `init?(payload:)`.
//
// Transport policy (see plan §4), decided per case by the sender:
//   • score snapshots  → updateApplicationContext (coalesced, background) +
//                         sendMessage when reachable (instant mirror + haptic)
//   • commands         → transferUserInfo (guaranteed-delivery FIFO queue) so
//                         "Finish & post" survives the phone being in a bag.

/// A discriminated message between the phone and the watch. Score travels as a
/// full snapshot (idempotent, last-writer-wins by `LiveMatchScore.seq`), never
/// as deltas; lifecycle actions travel as `command`.
public enum WatchSyncMessage: Hashable, Sendable {
    /// Latest full game state. Receiver adopts it only if `seq` is newer.
    case score(LiveMatchScore)
    /// A lifecycle action. Payload-carrying variants embed the relevant state.
    case command(WatchCommand)

    // Wire keys. `kind` discriminates; the rest are case-specific.
    private enum Key {
        static let kind = "kind"
        static let score = "score"
        static let command = "command"
    }
    private enum Kind {
        static let score = "score"
        static let command = "command"
    }

    /// Encode to a WCSession-transportable dictionary.
    public var payload: [String: Any] {
        switch self {
        case .score(let score):
            return [
                Key.kind: Kind.score,
                Key.score: WatchSyncCoding.encode(score),
            ]
        case .command(let command):
            return [
                Key.kind: Kind.command,
                Key.command: command.payload,
            ]
        }
    }

    /// Decode from a received WCSession dictionary. Returns nil on shape/version
    /// mismatch so a stray message can never crash the receiver.
    public init?(payload: [String: Any]) {
        guard let kind = payload[Key.kind] as? String else { return nil }
        switch kind {
        case Kind.score:
            guard
                let data = payload[Key.score] as? Data,
                let score = WatchSyncCoding.decode(LiveMatchScore.self, from: data)
            else { return nil }
            self = .score(score)
        case Kind.command:
            guard
                let dict = payload[Key.command] as? [String: Any],
                let command = WatchCommand(payload: dict)
            else { return nil }
            self = .command(command)
        default:
            return nil
        }
    }
}

/// Lifecycle actions the two devices exchange. Sent via `transferUserInfo` for
/// guaranteed delivery.
public enum WatchCommand: Hashable, Sendable {
    /// Begin a new game with the given starting configuration.
    case startGame(LiveMatchScore)
    /// End the current game (convert to a match activity on the phone).
    case endGame(LiveMatchScore)
    /// Start another game within the same session.
    case newGame(LiveMatchScore)
    /// Finish the whole session and post it (phone owns posting).
    case finishSession
    /// The phone discarded its live draft: clear the watch's game too.
    case discardSession

    private enum Key {
        static let action = "action"
        static let score = "score"
    }
    private enum Action {
        static let startGame = "startGame"
        static let endGame = "endGame"
        static let newGame = "newGame"
        static let finishSession = "finishSession"
        static let discardSession = "discardSession"
    }

    public var payload: [String: Any] {
        switch self {
        case .startGame(let score):
            return [Key.action: Action.startGame, Key.score: WatchSyncCoding.encode(score)]
        case .endGame(let score):
            return [Key.action: Action.endGame, Key.score: WatchSyncCoding.encode(score)]
        case .newGame(let score):
            return [Key.action: Action.newGame, Key.score: WatchSyncCoding.encode(score)]
        case .finishSession:
            return [Key.action: Action.finishSession]
        case .discardSession:
            return [Key.action: Action.discardSession]
        }
    }

    public init?(payload: [String: Any]) {
        guard let action = payload[Key.action] as? String else { return nil }
        func score() -> LiveMatchScore? {
            guard let data = payload[Key.score] as? Data else { return nil }
            return WatchSyncCoding.decode(LiveMatchScore.self, from: data)
        }
        switch action {
        case Action.startGame:
            guard let s = score() else { return nil }
            self = .startGame(s)
        case Action.endGame:
            guard let s = score() else { return nil }
            self = .endGame(s)
        case Action.newGame:
            guard let s = score() else { return nil }
            self = .newGame(s)
        case Action.finishSession:
            self = .finishSession
        case Action.discardSession:
            self = .discardSession
        default:
            return nil
        }
    }
}

/// JSON coding used for the `Codable` values embedded in WC payloads. Kept in
/// one place so both encode/decode use identical, forgiving settings.
enum WatchSyncCoding {
    static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}
