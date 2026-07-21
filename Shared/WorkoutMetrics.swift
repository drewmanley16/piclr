import Foundation

/// A transient snapshot streamed from Apple Watch while the iPhone app is
/// reachable. These values are intentionally never persisted or uploaded.
public struct LiveWorkoutMetrics: Codable, Hashable, Sendable {
    let heartRateBPM: Int?
    let averageHeartRateBPM: Int?
    let activeCaloriesKcal: Int?
    let sampledAt: Date

    init(
        heartRateBPM: Int?,
        averageHeartRateBPM: Int?,
        activeCaloriesKcal: Int?,
        sampledAt: Date = Date()
    ) {
        self.heartRateBPM = heartRateBPM
        self.averageHeartRateBPM = averageHeartRateBPM
        self.activeCaloriesKcal = activeCaloriesKcal
        self.sampledAt = sampledAt
    }

    private enum CodingKeys: String, CodingKey {
        case heartRateBPM, averageHeartRateBPM, activeCaloriesKcal, sampledAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        heartRateBPM = try values.decodeIfPresent(Int.self, forKey: .heartRateBPM)
        averageHeartRateBPM = try values.decodeIfPresent(Int.self, forKey: .averageHeartRateBPM)
        activeCaloriesKcal = try values.decodeIfPresent(Int.self, forKey: .activeCaloriesKcal)
        sampledAt = try values.decodeIfPresent(Date.self, forKey: .sampledAt) ?? Date()
    }
}

/// Final Apple Watch workout summary attached to a posted session. Live samples
/// stay in HealthKit; only these rounded aggregate values leave the watch.
public struct WorkoutMetrics: Codable, Hashable, Sendable {
    let averageHeartRateBPM: Int?
    let maximumHeartRateBPM: Int?
    let activeCaloriesKcal: Int?
    let startedAt: Date
    let endedAt: Date

    init(
        averageHeartRateBPM: Int?,
        maximumHeartRateBPM: Int?,
        activeCaloriesKcal: Int?,
        startedAt: Date,
        endedAt: Date
    ) {
        self.averageHeartRateBPM = averageHeartRateBPM
        self.maximumHeartRateBPM = maximumHeartRateBPM
        self.activeCaloriesKcal = activeCaloriesKcal
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}
