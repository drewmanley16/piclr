import Foundation

enum SkillFocus: String, CaseIterable, Identifiable {
    case serve = "Serve"
    case returnDepth = "Return Depth"
    case thirdShot = "Third Shot"
    case dinks = "Dinks"
    case resets = "Resets"
    case hands = "Hands"
    case positioning = "Positioning"
    case communication = "Communication"

    var id: String { rawValue }
}
