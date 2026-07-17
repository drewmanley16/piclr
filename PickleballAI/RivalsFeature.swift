import SwiftUI

// MARK: - Rivals

/// One head-to-head row: identity on the left, record + who's-hot streak on the
/// right. `emphasized` is the hero variant used on the profile card.
struct RivalRow: View {
    let rivalry: Rivalry
    var emphasized: Bool = false
    /// Opt out of avatar navigation when the row sits inside an already-tappable
    /// container (the profile Rivals card is a button into the Rivals sheet).
    var unlinked: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            ProfileAvatar(person: rivalry.person, size: emphasized ? 44 : 40, unlinked: unlinked)
            VStack(alignment: .leading, spacing: 2) {
                Text(rivalry.person.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(rivalry.streakLabel + " · last " + rivalry.lastPlayed.relativeLabel)
                    .font(.caption)
                    .foregroundStyle(streakColor)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(rivalry.recordLine)
                    .font((emphasized ? Font.title3 : .subheadline).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(rivalry.leadingYou ? Theme.accent : Theme.textPrimary)
                Text("\(rivalry.winRate)% · \(rivalry.games) games")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var streakColor: Color {
        if rivalry.streak > 0 { return Theme.accent }
        if rivalry.streak < 0 { return Theme.loss }
        return Theme.textSecondary
    }
}

struct RivalsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore

    private var rivalries: [Rivalry] {
        SessionStats(sessions: store.mySessions).rivalries.filter { $0.games >= 2 }
    }

    var body: some View {
        ProfileNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if rivalries.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "flame")
                                .font(.largeTitle)
                                .foregroundStyle(Theme.accent)
                            Text("No rivalries yet")
                                .font(.headline)
                                .foregroundStyle(Theme.textPrimary)
                            Text("Play the same opponent twice and your head-to-head shows up here.")
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(rivalries.enumerated()), id: \.element.id) { index, rivalry in
                                if index > 0 {
                                    Divider().overlay(Theme.hairline).padding(.leading, 56)
                                }
                                RivalRow(rivalry: rivalry)
                                    .padding(.vertical, 12)
                            }
                        }
                        .cardStyle(padding: 14)
                    }
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Rivals")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
