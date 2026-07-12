import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    profileHeader
                    progressCards
                    focusList
                    recentPartners
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Profile")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
        }
    }

    private var profileHeader: some View {
        HStack(spacing: 16) {
            AvatarView(initials: "DM")
                .scaleEffect(1.25)
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text("Drew Manley")
                    .font(.title2.weight(.bold))
                Text("@drew · Riverside Courts")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private var progressCards: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Progress")
                .font(.headline)

            HStack(spacing: 12) {
                StatPill(title: "Friend Rating", value: "3.42", systemImage: "chart.bar")
                StatPill(title: "Record", value: "13-11", systemImage: "trophy")
                StatPill(title: "Streak", value: "W3", systemImage: "flame")
            }
        }
    }

    private var focusList: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Current Focus", actionTitle: "Edit") {
            }

            VStack(spacing: 0) {
                FocusRow(skill: "Third-shot drops", detail: "31 of 50 quality reps last session", progress: 0.62)
                Divider()
                FocusRow(skill: "Transition resets", detail: "Less pop-up pressure this week", progress: 0.48)
                Divider()
                FocusRow(skill: "Middle communication", detail: "3 straight wins with Will", progress: 0.76)
            }
            .padding(.horizontal, 16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var recentPartners: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Best Partners")
                .font(.headline)

            VStack(spacing: 0) {
                ForEach(store.players.prefix(3)) { player in
                    HStack(spacing: 12) {
                        AvatarView(initials: player.avatarInitials)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(player.name)
                                .font(.body.weight(.medium))
                            Text("\(player.handle) · \(String(format: "%.2f", player.rating))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(player.name == "Will" ? "6-2" : "4-3")
                            .font(.headline.monospacedDigit())
                    }
                    .frame(minHeight: 60)
                    if player.id != store.players.prefix(3).last?.id {
                        Divider()
                    }
                }
            }
            .padding(.horizontal, 16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct FocusRow: View {
    var skill: String
    var detail: String
    var progress: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(skill)
                    .font(.body.weight(.medium))
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            ProgressView(value: progress)
        }
        .padding(.vertical, 12)
    }
}

