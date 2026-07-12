import Foundation

@MainActor
final class AppStore: ObservableObject {
    @Published var players: [Player]
    @Published var matches: [Match]
    @Published var sessions: [PracticeSession]
    @Published var groups: [PickleballGroup]

    init() {
        let drew = Player(id: UUID(), name: "Drew", handle: "@drew", rating: 3.42, avatarInitials: "DM")
        let will = Player(id: UUID(), name: "Will", handle: "@will", rating: 3.56, avatarInitials: "WI")
        let alex = Player(id: UUID(), name: "Alex", handle: "@alex", rating: 3.31, avatarInitials: "AX")
        let sam = Player(id: UUID(), name: "Sam", handle: "@sam", rating: 3.64, avatarInitials: "SM")
        let jordan = Player(id: UUID(), name: "Jordan", handle: "@jordan", rating: 3.18, avatarInitials: "JR")
        let maya = Player(id: UUID(), name: "Maya", handle: "@maya", rating: 3.73, avatarInitials: "MY")
        players = [drew, will, alex, sam, jordan, maya]

        matches = [
            Match(
                id: UUID(),
                date: Date().addingTimeInterval(-60 * 28),
                location: "Riverside Courts",
                teamOne: [drew, will],
                teamTwo: [alex, sam],
                teamOneScore: 11,
                teamTwoScore: 8,
                matchType: .casual,
                focus: .communication,
                note: "Middle calls were cleaner after switching Will left."
            ),
            Match(
                id: UUID(),
                date: Date().addingTimeInterval(-60 * 60 * 5),
                location: "Riverside Courts",
                teamOne: [maya, drew],
                teamTwo: [will, jordan],
                teamOneScore: 7,
                teamTwoScore: 11,
                matchType: .ladder,
                focus: .thirdShot,
                note: "Got punished when third shots floated high."
            ),
            Match(
                id: UUID(),
                date: Date().addingTimeInterval(-60 * 60 * 28),
                location: "Eastside YMCA",
                teamOne: [sam, drew],
                teamTwo: [alex, maya],
                teamOneScore: 12,
                teamTwoScore: 10,
                matchType: .drillGame,
                focus: .resets,
                note: "Transition zone resets finally held up late."
            )
        ]

        sessions = [
            PracticeSession(
                id: UUID(),
                date: Date().addingTimeInterval(-60 * 60 * 2),
                location: "Riverside Courts",
                durationMinutes: 92,
                drills: [
                    Drill(id: UUID(), name: "Cross-court dinks", durationMinutes: 12, attempts: nil, makes: nil),
                    Drill(id: UUID(), name: "Third-shot drops", durationMinutes: 18, attempts: 50, makes: 31)
                ],
                matchesPlayed: 5,
                wins: 3,
                focus: .thirdShot,
                takeaway: "Better results when aiming drop height over pace."
            ),
            PracticeSession(
                id: UUID(),
                date: Date().addingTimeInterval(-60 * 60 * 48),
                location: "Eastside YMCA",
                durationMinutes: 55,
                drills: [
                    Drill(id: UUID(), name: "Deep serves", durationMinutes: 15, attempts: 60, makes: 51),
                    Drill(id: UUID(), name: "Kitchen hands", durationMinutes: 10, attempts: nil, makes: nil)
                ],
                matchesPlayed: 2,
                wins: 1,
                focus: .serve,
                takeaway: "Deep middle serves created weaker returns."
            )
        ]

        groups = [
            PickleballGroup(
                id: UUID(),
                name: "Saturday Morning Crew",
                location: "Riverside Courts",
                members: [drew, will, alex, sam, jordan, maya],
                leaderboard: [
                    LeaderboardRow(id: UUID(), player: maya, wins: 18, losses: 7, streak: 4),
                    LeaderboardRow(id: UUID(), player: sam, wins: 16, losses: 9, streak: 2),
                    LeaderboardRow(id: UUID(), player: will, wins: 14, losses: 10, streak: 1),
                    LeaderboardRow(id: UUID(), player: drew, wins: 13, losses: 11, streak: 3),
                    LeaderboardRow(id: UUID(), player: alex, wins: 11, losses: 13, streak: 0),
                    LeaderboardRow(id: UUID(), player: jordan, wins: 8, losses: 15, streak: 0)
                ]
            )
        ]
    }

    var feedItems: [FeedItem] {
        let matchItems = matches.map(FeedItem.match)
        let sessionItems = sessions.map(FeedItem.session)
        return (matchItems + sessionItems).sorted { $0.date > $1.date }
    }
}
