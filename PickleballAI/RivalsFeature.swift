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
    /// Guests get an "Invite" chip — but not inside an enclosing tappable card,
    /// where a nested ShareLink would fight the card's own tap. The profile
    /// Rivals card passes `false`; the standalone Rivals sheet keeps it on.
    var showsInvite: Bool = true

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
            if showsInvite, rivalry.person.profileId == nil {
                GuestInviteButton(guestName: rivalry.person.displayName)
            }
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

// MARK: - Heating up

extension Rivalry {
    /// You've won the last 2+ meetings.
    var youAreHot: Bool { streak >= 2 }
    /// They've won the last 2+ meetings — the one that stings.
    var theyAreHot: Bool { streak <= -2 }
    /// Someone is on a current 2+ meeting run either way.
    var isHot: Bool { abs(streak) >= 2 }

    /// First name for momentum sentences ("Wesley has taken the last 3").
    var firstName: String {
        person.displayName.split(separator: " ").first.map(String.init) ?? person.displayName
    }
    /// The "who's hot" sentence for the Heating up surface.
    var momentumLabel: String {
        if streak >= 2 { return "You've taken the last \(streak)" }
        if streak <= -2 { return "\(firstName) has taken the last \(-streak)" }
        return streakLabel
    }
}

extension SessionStats {
    /// Rivals with current momentum — someone's won the last 2+ meetings.
    /// Most-recent first, then hottest streak. Powers the "who's heating up"
    /// surface (and, later, the heating-up push). See [[SessionStats]].
    var heatingUp: [Rivalry] {
        rivalries
            .filter { $0.isHot && $0.games >= 2 }
            .sorted { $0.lastPlayed != $1.lastPlayed ? $0.lastPlayed > $1.lastPlayed : abs($0.streak) > abs($1.streak) }
    }
}

/// A row on the Heating up surface: momentum sentence + a flame that's lime when
/// you're rolling, loss-red when they are.
struct HeatingUpRow: View {
    let rivalry: Rivalry

    var body: some View {
        HStack(spacing: 12) {
            ProfileAvatar(person: rivalry.person, size: 40, unlinked: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(rivalry.person.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(rivalry.momentumLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(heatColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "flame.fill")
                .font(.footnote.weight(.bold))
                .foregroundStyle(heatColor)
            Text(rivalry.recordLine)
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(rivalry.leadingYou ? Theme.accent : Theme.textPrimary)
        }
    }

    private var heatColor: Color { rivalry.theyAreHot ? Theme.loss : Theme.accent }
}

struct RivalsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore

    private var stats: SessionStats {
        SessionStats(sessions: store.mySessions, playerID: store.currentProfile?.id)
    }
    private var rivalries: [Rivalry] { stats.rivalries.filter { $0.games >= 2 } }
    private var heatingUp: [Rivalry] { stats.heatingUp }

    var body: some View {
        ProfileNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !heatingUp.isEmpty { heatingUpSection }
                    if rivalries.isEmpty {
                        emptyState
                    } else {
                        allRivalriesSection
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

    private var heatingUpSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Heating up", systemImage: "flame.fill")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            VStack(spacing: 0) {
                ForEach(Array(heatingUp.enumerated()), id: \.element.id) { index, rivalry in
                    if index > 0 { Divider().overlay(Theme.hairline).padding(.leading, 52) }
                    HeatingUpRow(rivalry: rivalry).padding(.vertical, 12)
                }
            }
            .cardStyle(padding: 14)
        }
    }

    private var allRivalriesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("All rivalries")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            VStack(spacing: 0) {
                ForEach(Array(rivalries.enumerated()), id: \.element.id) { index, rivalry in
                    if index > 0 { Divider().overlay(Theme.hairline).padding(.leading, 56) }
                    RivalRow(rivalry: rivalry).padding(.vertical, 12)
                }
            }
            .cardStyle(padding: 14)
        }
    }

    private var emptyState: some View {
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
    }
}
