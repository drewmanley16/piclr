import SwiftUI

struct GroupsView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        NavigationStack {
            List {
                if let group = store.groups.first {
                    Section {
                        GroupSummaryCard(group: group)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 12, trailing: 16))
                            .listRowBackground(Color.clear)
                    }

                    Section("Leaderboard") {
                        ForEach(Array(group.leaderboard.enumerated()), id: \.element.id) { index, row in
                            LeaderboardRowView(rank: index + 1, row: row)
                        }
                    }
                    .listRowBackground(Theme.surface)

                    Section("Rivalries") {
                        RivalryRow(title: "Drew vs Will", subtitle: "Drew leads 6-4", systemImage: "flame")
                        RivalryRow(title: "Maya & Sam", subtitle: "Best pair, 9-2 together", systemImage: "person.2.fill")
                        RivalryRow(title: "Alex wants a rematch", subtitle: "Lost last two by 3 total points", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .listRowBackground(Theme.surface)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Groups")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                    } label: {
                        Image(systemName: "person.badge.plus")
                    }
                    .accessibilityLabel("Invite player")
                }
            }
        }
    }
}

struct GroupSummaryCard: View {
    var group: PickleballGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(group.name)
                    .font(.title3.weight(.semibold))
                Text(group.location)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                StatPill(title: "Members", value: "\(group.members.count)", systemImage: "person.3")
                StatPill(title: "Matches", value: "41", systemImage: "sportscourt")
                StatPill(title: "Active", value: "Today", systemImage: "bolt")
            }
        }
        .padding(.vertical, 8)
    }
}

struct LeaderboardRowView: View {
    var rank: Int
    var row: LeaderboardRow

    var body: some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 28)

            AvatarView(initials: row.player.avatarInitials)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.player.name)
                    .font(.body.weight(.medium))
                Text("\(row.wins)-\(row.losses) record")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(row.winRate)%")
                    .font(.headline.monospacedDigit())
                Text(row.streak > 0 ? "W\(row.streak)" : "No streak")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 56)
    }
}

struct RivalryRow: View {
    var title: String
    var subtitle: String
    var systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(Theme.accent)
                .frame(width: 32, height: 32)
                .background(Theme.accentSoft, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 52)
    }
}
