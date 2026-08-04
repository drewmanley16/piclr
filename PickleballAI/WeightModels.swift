import Foundation

// MARK: - Units

/// Display unit for weight. **Pounds are canonical on the wire** — kg is purely
/// a presentation choice, so switching units never rewrites a single logged
/// entry (and a user who flips back sees the exact numbers they typed).
enum WeightUnit: String, CaseIterable, Identifiable, Hashable {
    case pounds = "lb"
    case kilograms = "kg"

    var id: String { rawValue }
    var label: String { rawValue }

    private static let poundsPerKilogram = 2.204_622_621_85

    func fromPounds(_ pounds: Double) -> Double {
        switch self {
        case .pounds:     return pounds
        case .kilograms:  return pounds / Self.poundsPerKilogram
        }
    }

    func toPounds(_ value: Double) -> Double {
        switch self {
        case .pounds:     return value
        case .kilograms:  return value * Self.poundsPerKilogram
        }
    }

    /// One decimal reads right at body scale in both units ("168.4", "76.4")
    /// while staying honest about a half-pound change.
    func display(pounds: Double) -> String {
        String(format: "%.1f", fromPounds(pounds))
    }

    func displayWithUnit(pounds: Double) -> String {
        "\(display(pounds: pounds)) \(label)"
    }

    /// A signed change, unit-converted — "−2.4 lb", "+0.8 kg". Uses a real
    /// minus sign so the digits stay optically aligned in the history list.
    func displayDelta(pounds: Double) -> String {
        let magnitude = fromPounds(abs(pounds))
        return String(format: "%@%.1f %@", pounds < 0 ? "−" : "+", magnitude, label)
    }
}

// MARK: - Weight log (read models)

/// One weigh-in. The table holds at most one row per user per day, so `day`
/// uniquely identifies an entry within the log.
struct WeightEntry: Identifiable, Decodable, Hashable {
    let id: UUID
    /// The calendar day of the weigh-in, at local midnight.
    let day: Date
    let weightPounds: Double

    enum CodingKeys: String, CodingKey {
        case id
        case day = "recorded_on"
        case weightPounds = "weight_pounds"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        day = WeightEntry.day(from: try c.decode(String.self, forKey: .day))
        weightPounds = try c.decode(Double.self, forKey: .weightPounds)
    }

    init(id: UUID, day: Date, weightPounds: Double) {
        self.id = id
        self.day = day
        self.weightPounds = weightPounds
    }
}

extension WeightEntry {
    /// `recorded_on` ⇄ `Date`, through the app's shared Postgres-date
    /// formatter (see `DateFormatting.postgresDate` for why it isn't ISO-8601).
    static func day(from string: String) -> Date {
        DateFormatting.postgresDate.date(from: string) ?? Calendar.current.startOfDay(for: Date())
    }

    static func string(from day: Date) -> String {
        DateFormatting.postgresDate.string(from: day)
    }
}

struct WeightSettingsRow: Decodable, Hashable {
    let unit: WeightUnit
    let goalPounds: Double?

    enum CodingKeys: String, CodingKey {
        case unit
        case goalPounds = "goal_pounds"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // An unrecognized unit should never strand the UI on a blank screen.
        unit = WeightUnit(rawValue: try c.decode(String.self, forKey: .unit)) ?? .pounds
        goalPounds = try c.decodeIfPresent(Double.self, forKey: .goalPounds)
    }
}

// MARK: - Weight log (write models)

/// Upserted on `(user_id, recorded_on)` so re-logging a day corrects it.
struct WeightEntryUpsert: Encodable {
    let userId: UUID
    let recordedOn: String
    let weightPounds: Double

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case recordedOn = "recorded_on"
        case weightPounds = "weight_pounds"
    }
}

struct WeightSettingsUpsert: Encodable {
    let userId: UUID
    let unit: String
    let goalPounds: Double?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case unit
        case goalPounds = "goal_pounds"
    }

    /// Hand-written so a cleared goal writes an explicit `null`. The synthesized
    /// encoder uses `encodeIfPresent`, which would drop the key entirely and
    /// leave the old goal standing on the server.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(userId, forKey: .userId)
        try c.encode(unit, forKey: .unit)
        try c.encode(goalPounds, forKey: .goalPounds)
    }
}
