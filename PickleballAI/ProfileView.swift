import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showSettings = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                profileHeader
                weeklyActivity
                measures
                postings
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Theme.background.ignoresSafeArea())
        .safeAreaInset(edge: .top) {
            AppHeader(title: "Profile") {
                HeaderCircleButton(systemImage: "gearshape", accessibilityTitle: "Settings") {
                    showSettings = true
                }
            }
            .background(Theme.background)
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
                .presentationDetents([.medium, .large])
        }
    }

    private var profileHeader: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                Text("DM")
                    .font(.title.weight(.bold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 72, height: 72)
                    .background(Theme.surfaceElevated, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Drew Manley")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("@drew · Riverside Courts")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()
            }

            HStack(spacing: 0) {
                FollowStat(value: "128", label: "Followers")
                FollowStat(value: "96", label: "Following")
                FollowStat(value: "\(store.feedItems.count)", label: "Posts")
            }
        }
        .cardStyle()
    }

    private var weeklyActivity: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This week")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)

            HStack(spacing: 12) {
                StatPill(title: "Sessions", value: "4", systemImage: "figure.pickleball")
                StatPill(title: "Hours", value: "6.5", systemImage: "clock")
                StatPill(title: "Record", value: "13-11", systemImage: "trophy")
            }
        }
    }

    private var measures: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Measures")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)

            VStack(spacing: 0) {
                MeasureRow(label: "Rating", value: "3.42 DUPR")
                rowDivider
                MeasureRow(label: "Paddle", value: "Joola Perseus")
                rowDivider
                MeasureRow(label: "Preferred side", value: "Left")
            }
            .padding(.horizontal, 16)
            .cardStyle(padding: 0)
        }
    }

    private var postings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your Posts")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)

            ForEach(store.feedItems) { item in
                PostingRow(item: item)
            }
        }
    }

    private var rowDivider: some View {
        Divider().overlay(Theme.hairline)
    }
}

struct FollowStat: View {
    var value: String
    var label: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct MeasureRow: View {
    var label: String
    var value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Text(value)
                .font(.body.weight(.medium))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(minHeight: 48)
    }
}

struct PostingRow: View {
    var item: FeedItem

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
                .background(Theme.accentSoft, in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(item.date.relativeLabel)
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
        }
        .cardStyle()
    }

    private var icon: String {
        switch item {
        case .match: return "trophy"
        case .session: return "figure.pickleball"
        }
    }

    private var title: String {
        switch item {
        case .match(let match): return "\(match.winningTeamNames) won"
        case .session(let session): return "\(session.focus.rawValue) session"
        }
    }

    private var subtitle: String {
        switch item {
        case .match(let match): return "\(match.teamOneScore)–\(match.teamTwoScore) at \(match.location)"
        case .session(let session): return "\(session.durationMinutes) min at \(session.location)"
        }
    }
}

// MARK: - Settings

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SettingsRow(label: "Account", systemImage: "person")
                    SettingsRow(label: "Notifications", systemImage: "bell")
                    SettingsRow(label: "Privacy", systemImage: "lock")
                }

                Section {
                    SettingsRow(label: "Help & Support", systemImage: "questionmark.circle")
                    SettingsRow(label: "About", systemImage: "info.circle")
                }

                Section {
                    Button(role: .destructive) {
                    } label: {
                        Text("Log out")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .listRowBackground(Theme.surface)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct SettingsRow: View {
    var label: String
    var systemImage: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(Theme.accent)
                .frame(width: 28)
            Text(label)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(minHeight: 44)
    }
}
