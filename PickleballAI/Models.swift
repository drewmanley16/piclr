import Foundation

enum SkillLevel: String, CaseIterable, Identifiable, Codable {
    case beginner
    case intermediate
    case advanced
    case dupr

    var id: String { rawValue }

    var title: String {
        switch self {
        case .beginner: return "Beginner"
        case .intermediate: return "Intermediate"
        case .advanced: return "Advanced"
        case .dupr: return "I have a DUPR rating"
        }
    }

    var subtitle: String {
        switch self {
        case .beginner: return "Newer player, learning rallies"
        case .intermediate: return "Comfortable with games and drills"
        case .advanced: return "Competitive rec or tournament player"
        case .dupr: return "Use your exact rating as the seed"
        }
    }
}
