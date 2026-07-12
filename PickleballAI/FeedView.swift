import SwiftUI

struct FeedView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var isShowingQuickLog: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    topStats

                    SectionHeader(title: "Crew Activity", actionTitle: "Log") {
                        isShowingQuickLog = true
                    }

                    LazyVStack(spacing: 12) {
                        ForEach(store.feedItems) { item in
                            FeedCard(item: item)
                        }
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("pickleball.ai")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingQuickLog = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Log match or session")
                }
            }
        }
    }

    private var topStats: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("This week")
                .font(.headline)

            HStack(spacing: 12) {
                StatPill(title: "Matches", value: "8", systemImage: "sportscourt")
                StatPill(title: "Win Rate", value: "63%", systemImage: "chart.line.uptrend.xyaxis")
                StatPill(title: "Focus", value: "Drops", systemImage: "scope")
            }
        }
    }
}

struct FeedCard: View {
    var item: FeedItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch item {
            case .match(let match):
                MatchFeedContent(match: match)
            case .session(let session):
                SessionFeedContent(session: session)
            }

            HStack(spacing: 16) {
                Button {
                } label: {
                    Label("React", systemImage: "hand.thumbsup")
                }
                .buttonStyle(.borderless)
                .frame(minHeight: 44)

                Button {
                } label: {
                    Label("Rematch", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderless)
                .frame(minHeight: 44)

                Spacer()
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct MatchFeedContent: View {
    var match: Match

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                AvatarView(initials: match.teamOne.first?.avatarInitials ?? "PB")
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(match.winningTeamNames) won")
                        .font(.headline)
                    Text("\(match.summary) at \(match.location)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(match.date.relativeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                ScoreBox(label: "Team 1", score: match.teamOneScore)
                ScoreBox(label: "Team 2", score: match.teamTwoScore)
                FocusChip(title: match.focus.rawValue)
            }

            Text(match.note)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

struct SessionFeedContent: View {
    var session: PracticeSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "figure.pickleball")
                    .font(.title3)
                    .foregroundStyle(.teal)
                    .frame(width: 40, height: 40)
                    .background(Color.teal.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text("Practice session logged")
                        .font(.headline)
                    Text("\(session.durationMinutes) min at \(session.location)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(session.date.relativeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                FocusChip(title: "\(session.wins)-\(max(session.matchesPlayed - session.wins, 0))")
                FocusChip(title: session.focus.rawValue)
                FocusChip(title: "\(session.drills.count) drills")
            }

            Text(session.takeaway)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

struct ScoreBox: View {
    var label: String
    var score: Int

    var body: some View {
        VStack(spacing: 4) {
            Text("\(score)")
                .font(.title3.weight(.bold))
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 72, minHeight: 56)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct FocusChip: View {
    var title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .frame(minHeight: 32)
            .background(Color.teal.opacity(0.12), in: Capsule())
            .foregroundStyle(.teal)
    }
}
