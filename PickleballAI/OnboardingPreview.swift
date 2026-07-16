import SwiftUI

struct OnboardingPreviewCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                ProfileAvatar(url: nil, initials: "DM", size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Drew & Maya won")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text("11-8 at Riverside Courts")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Text("now")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }

            HStack(spacing: 8) {
                FocusChip(title: "Third Shot")
                FocusChip(title: "4 wins")
                FocusChip(title: "Crew")
            }

            Divider().overlay(Theme.hairline)

            VStack(alignment: .leading, spacing: 10) {
                LeaderboardPreviewRow(rank: 1, name: "Maya", record: "18-7")
                LeaderboardPreviewRow(rank: 2, name: "Sam", record: "16-9")
                LeaderboardPreviewRow(rank: 3, name: "Drew", record: "13-11")
            }
        }
        .cardStyle()
    }
}

struct LeaderboardPreviewRow: View {
    var rank: Int
    var name: String
    var record: String

    var body: some View {
        HStack {
            Text("\(rank)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 28, alignment: .leading)
            Text(name)
                .font(.body.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Text(record)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
        }
    }
}
