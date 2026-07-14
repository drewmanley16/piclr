import SwiftUI

enum PlayerRole: String, Identifiable { case partner, opponent; var id: String { rawValue } }

// MARK: - Activity editor (practice or match)

struct ActivityEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State var activity: DraftActivity
    var onSave: (DraftActivity) -> Void

    @State private var picker: PlayerRole?

    var body: some View {
        NavigationStack {
            Form {
                if activity.kind == .practice {
                    practiceFields
                } else {
                    matchFields
                }

                Section {
                    Button {
                        onSave(activity)
                        dismiss()
                    } label: {
                        Text("Save")
                            .font(.headline)
                            .foregroundStyle(Theme.background)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .disabled(!isValid)
                    .listRowBackground(isValid ? Theme.accent : Theme.surfaceElevated)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .listRowBackground(Theme.surface)
            .navigationTitle(activity.kind == .match ? "Match" : "Practice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .sheet(item: $picker) { role in
                PlayerPickerSheet(exclude: excludedMemberIds) { player in
                    switch role {
                    case .partner: activity.partners.append(player)
                    case .opponent: activity.opponents.append(player)
                    }
                }
            }
        }
    }

    private var practiceFields: some View {
        Group {
            Section("Practice") {
                Picker("Focus", selection: $activity.focus) {
                    Text("None").tag("")
                    ForEach(SkillFocus.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                TextField("Reps / drills (e.g. 50 third-shot drops)", text: $activity.reps)
            }
            Section("Notes") {
                TextField("What did you work on?", text: $activity.notes, axis: .vertical)
                    .lineLimit(2...5)
            }
        }
    }

    private var matchFields: some View {
        Group {
            Section("Score") {
                Stepper("You: \(activity.teamScore)", value: $activity.teamScore, in: 0...30)
                Stepper("Them: \(activity.opponentScore)", value: $activity.opponentScore, in: 0...30)
                HStack {
                    Text("Result")
                    Spacer()
                    Text(activity.won ? "Win" : "Loss")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(activity.won ? Theme.accent : Theme.textSecondary)
                }
            }
            Section("Partners") {
                PlayerChips(players: $activity.partners)
                Button { picker = .partner } label: { Label("Add partner", systemImage: "person.badge.plus") }
            }
            Section("Opponents") {
                PlayerChips(players: $activity.opponents)
                Button { picker = .opponent } label: { Label("Add opponent", systemImage: "person.badge.plus") }
            }
        }
    }

    private var isValid: Bool {
        activity.kind == .match || !activity.focus.isEmpty || !activity.reps.isEmpty || !activity.notes.isEmpty
    }

    private var excludedMemberIds: Set<UUID> {
        Set((activity.partners + activity.opponents).compactMap { $0.profile?.id })
    }
}

struct PlayerChips: View {
    @Binding var players: [DraftPlayer]

    var body: some View {
        if players.isEmpty {
            Text("None yet")
                .font(.subheadline)
                .foregroundStyle(Theme.textTertiary)
        } else {
            ForEach(players) { player in
                HStack(spacing: 10) {
                    Text(player.displayName).foregroundStyle(Theme.textPrimary)
                    if let handle = player.handle {
                        Text(handle).font(.caption).foregroundStyle(Theme.textSecondary)
                    } else {
                        Text("guest").font(.caption).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    Button {
                        players.removeAll { $0.id == player.id }
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Player picker (members via search + free-text guest)

struct PlayerPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    var exclude: Set<UUID>
    var onPick: (DraftPlayer) -> Void

    @State private var query = ""

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            List {
                if !trimmed.isEmpty {
                    Section {
                        Button {
                            onPick(DraftPlayer(guestName: trimmed))
                            dismiss()
                        } label: {
                            Label("Add \"\(trimmed)\" as guest", systemImage: "person.crop.circle.badge.plus")
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }

                Section("Members") {
                    let results = store.searchResults.filter { !exclude.contains($0.id) }
                    if results.isEmpty {
                        Text(trimmed.isEmpty ? "Search by name or @username" : "No members found")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textTertiary)
                    } else {
                        ForEach(results) { profile in
                            Button {
                                onPick(DraftPlayer(profile: profile))
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    AvatarView(initials: profile.initials)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(profile.displayName).foregroundStyle(Theme.textPrimary)
                                        Text("@\(profile.username)").font(.caption).foregroundStyle(Theme.textSecondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .listRowBackground(Theme.surface)
            .searchable(text: $query, prompt: "Name or @username")
            .task(id: query) {
                await store.searchProfilesAfterTyping(query: query)
            }
            .navigationTitle("Add player")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onDisappear { store.searchResults = [] }
        }
    }

}
