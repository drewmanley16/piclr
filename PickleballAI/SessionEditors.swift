import SwiftUI

enum PlayerRole: String, Identifiable { case partner, opponent; var id: String { rawValue } }

// MARK: - Activity editor (practice or match)

struct ActivityEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State var activity: DraftActivity
    /// Non-nil for a quick log, which is entered after play and so has no
    /// elapsed time to derive a duration from. A live session leaves this nil
    /// and times itself.
    var duration: Binding<Int>?
    /// Return false to keep the editor open — quick log posts straight to the
    /// backend from here, and a failed post must not discard what was typed.
    var onSave: (DraftActivity) async -> Bool

    @State private var picker: PlayerRole?
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                if activity.kind == .practice {
                    practiceFields
                } else {
                    matchFields
                }
                if let duration { durationField(duration) }

                Section {
                    Button {
                        isSaving = true
                        Task {
                            let saved = await onSave(activity)
                            isSaving = false
                            if saved { dismiss() }
                        }
                    } label: {
                        Text(isSaving ? "Saving…" : "Save")
                            .font(.headline)
                            .foregroundStyle(Theme.background)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .disabled(!isValid || isSaving)
                    .listRowBackground(isValid && !isSaving ? Theme.accent : Theme.surfaceElevated)
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
                    case .partner:
                        guard canAddPartner else { return }
                        activity.partners.append(player)
                    case .opponent:
                        guard canAddOpponent else { return }
                        activity.opponents.append(player)
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
            Section("Format") {
                Picker("Match format", selection: $activity.matchFormat) {
                    ForEach(MatchFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: activity.matchFormat) { _, _ in
                    Haptics.tap()
                    activity.normalizeRosterForFormat()
                }
            }
            Section {
                ScorePad(teamScore: $activity.teamScore, opponentScore: $activity.opponentScore)
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                    .listRowBackground(Theme.surface)
            }
            if activity.matchFormat == .doubles {
                Section("Partner") {
                    PlayerChips(players: $activity.partners)
                    Button { picker = .partner } label: {
                        Label(
                            canAddPartner ? "Add partner" : "Your side is full",
                            systemImage: canAddPartner ? "person.badge.plus" : "person.2.fill"
                        )
                    }
                    .disabled(!canAddPartner)
                }
            }
            Section(activity.matchFormat == .singles ? "Opponent" : "Opponents") {
                PlayerChips(players: $activity.opponents)
                Button { picker = .opponent } label: {
                    Label(
                        canAddOpponent ? "Add opponent" : "Opponent side is full",
                        systemImage: canAddOpponent
                            ? "person.badge.plus"
                            : (activity.matchFormat == .singles ? "person.fill" : "person.2.fill")
                    )
                }
                .disabled(!canAddOpponent)
            }
            Section("Notes") {
                TextField("How did the game go?", text: $activity.notes, axis: .vertical)
                    .lineLimit(2...5)
            }
        }
    }

    private func durationField(_ duration: Binding<Int>) -> some View {
        Section("Duration") {
            Stepper(value: duration, in: 15...480, step: 15) {
                HStack {
                    Text("How long did you play?")
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text(Self.durationLabel(duration.wrappedValue))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            .frame(minHeight: 44)
        }
    }

    static func durationLabel(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }

    private var isValid: Bool {
        activity.kind == .match || !activity.focus.isEmpty || !activity.reps.isEmpty || !activity.notes.isEmpty
    }

    private var canAddPartner: Bool {
        activity.partners.count < activity.maxPartners
    }

    private var canAddOpponent: Bool {
        activity.opponents.count < activity.maxOpponents
    }

    private var excludedMemberIds: Set<UUID> {
        Set((activity.partners + activity.opponents).compactMap { $0.profile?.id })
    }
}

/// Courtside scoreboard for entering a match result: two big columns, the winner
/// lit in accent. The score is both tap-to-type (tap the number, the number pad
/// opens, type it) and tap-to-step (+/-), so logging is as fast as the user
/// wants. This is the moment of primary value — it should feel like a
/// scoreboard, not a form.
struct ScorePad: View {
    @Binding var teamScore: Int
    @Binding var opponentScore: Int

    enum Side { case you, them }
    @FocusState private var focused: Side?

    private var youWon: Bool { teamScore > opponentScore }
    private var tied: Bool { teamScore == opponentScore }

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                ScoreColumn(label: "YOU", score: $teamScore, winning: youWon && !tied, side: .you, focused: $focused)
                Text("–")
                    .font(.title.weight(.light))
                    .foregroundStyle(Theme.textTertiary)
                ScoreColumn(label: "THEM", score: $opponentScore, winning: !youWon && !tied, side: .them, focused: $focused)
            }

            Text(tied ? "Tied" : (youWon ? "Win" : "Loss"))
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tied ? Theme.textSecondary : (youWon ? Theme.win : Theme.loss))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background((tied ? Theme.surfaceElevated : (youWon ? Theme.win : Theme.loss).opacity(0.14)), in: Capsule())
                .animation(.snappy, value: youWon)
                .animation(.snappy, value: tied)
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                if focused != nil {
                    Spacer()
                    Button("Done") { focused = nil }
                        .font(.body.weight(.semibold))
                }
            }
        }
    }
}

/// One score column. Tapping the number focuses a hidden number-pad field (the
/// current score shows as a solid prompt, so typing replaces it); the +/-
/// buttons step it. Both paths write the same clamped 0…30 `score` binding.
private struct ScoreColumn: View {
    let label: String
    @Binding var score: Int
    let winning: Bool
    let side: ScorePad.Side
    @FocusState.Binding var focused: ScorePad.Side?

    /// Only holds keystrokes while editing; idle it's empty and the prompt (the
    /// real score) is what's shown, so the number always renders in full color.
    @State private var text = ""

    private var numberColor: Color { winning ? Theme.accent : Theme.textPrimary }

    var body: some View {
        VStack(spacing: 12) {
            Text(label)
                .font(.caption2.weight(.bold))
                .tracking(1)
                .foregroundStyle(winning ? Theme.accent : Theme.textTertiary)

            TextField("", text: $text, prompt: Text("\(score)").foregroundColor(numberColor))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .font(Theme.scoreboard(56))
                .foregroundStyle(numberColor)
                .tint(Theme.accent)
                .frame(maxWidth: .infinity)
                .focused($focused, equals: side)
                .onChange(of: text) { _, new in
                    let digits = String(new.filter(\.isNumber).prefix(2))
                    if digits != new { text = digits; return }
                    if let value = Int(digits) {
                        let clamped = min(value, 30)
                        if clamped != score { Haptics.tap(); score = clamped }
                        if clamped != value { text = "\(clamped)" }
                    }
                }
                .onChange(of: focused) { _, now in
                    // Clear on focus so the first keystroke replaces the score;
                    // clear on blur so the prompt (score) shows again idle.
                    text = ""
                }

            HStack(spacing: 14) {
                stepButton("minus", enabled: score > 0) {
                    if score > 0 { Haptics.tap(); score -= 1; text = "" }
                }
                stepButton("plus", enabled: score < 30) {
                    if score < 30 { Haptics.tap(); score += 1; text = "" }
                }
            }
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(
            winning ? Theme.accentSoft : Theme.surfaceElevated,
            in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
        )
    }

    private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3.weight(.bold))
                .foregroundStyle(enabled ? Theme.textPrimary : Theme.textTertiary)
                .frame(width: 52, height: 52)
                .background(Theme.surface, in: Circle())
                .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(symbol == "plus" ? "Add point" : "Remove point")
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
    @Environment(AppStore.self) private var store
    var exclude: Set<UUID>
    var onPick: (DraftPlayer) -> Void

    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Friends (people you follow), shown by default for one-tap adding.
    private var friends: [Profile] {
        store.following.compactMap(\.profile).filter { !exclude.contains($0.id) }
    }

    private var members: [Profile] {
        trimmed.isEmpty ? friends : store.searchResults.filter { !exclude.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(Theme.textTertiary)
                        TextField("Search by name or @username", text: $query)
                            .focused($searchFocused)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        if !query.isEmpty {
                            Button { query = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

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

                Section(trimmed.isEmpty ? "Friends" : "Members") {
                    if members.isEmpty {
                        Text(trimmed.isEmpty
                             ? "Follow people to add them here, or search by name."
                             : "No members found")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textTertiary)
                    } else {
                        ForEach(members) { profile in
                            Button {
                                onPick(DraftPlayer(profile: profile))
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    ProfileAvatar(profile: profile, size: 40, unlinked: true)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(profile.displayName).foregroundStyle(Theme.textPrimary)
                                        Text("@\(profile.username)").font(.caption).foregroundStyle(Theme.textSecondary)
                                    }
                                    Spacer()
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .listRowBackground(Theme.surface)
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
