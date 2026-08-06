import SwiftUI
import PhotosUI

// MARK: - Active session (live builder)

struct ActiveSessionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store

    let existingSession: FeedSession?
    /// When true, this is the persistent "live" session — changes sync back to
    /// store.activeDraft so it survives leaving the tab, and the sheet can be
    /// dismissed freely to resume later.
    let isLive: Bool

    /// Backing store for the edit / one-off paths. A live session is *not* kept
    /// here — see `draft` — but this still holds the frozen copy shown while the
    /// post celebration plays, after `store.activeDraft` has been cleared.
    @State private var localDraft: SessionDraft
    @State private var editor: ActivityEditorRoute?
    @State private var showDiscardConfirm = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showLocationPicker = false
    @State private var showCelebration = false
    @State private var celebrationTitle = "Session posted"
    @State private var isSubmitting = false

    init(existingSession: FeedSession? = nil, isLive: Bool = false) {
        self.existingSession = existingSession
        self.isLive = isLive
        _localDraft = State(initialValue: existingSession.map(SessionDraft.init(session:)) ?? SessionDraft())
    }

    private var isEditing: Bool { existingSession != nil }

    /// A live session reads and writes `store.activeDraft` directly rather than
    /// mirroring it into local state. Apple Watch messages mutate that same
    /// storage while this sheet is open (a finished game becomes an activity),
    /// so a local copy would go stale and the next keystroke here would write it
    /// back over the watch's changes.
    private var draft: SessionDraft {
        get { isLive ? (store.activeDraft ?? localDraft) : localDraft }
        nonmutating set {
            if isLive { store.activeDraft = newValue } else { localDraft = newValue }
        }
    }

    /// `draft` is computed, so it has no projected value; sub-bindings for the
    /// form fields come from here instead of `$draft`.
    private var draftBinding: Binding<SessionDraft> {
        Binding(get: { draft }, set: { draft = $0 })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    detailsCard
                    addButtons
                    activityList
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(isEditing ? "Edit Session" : "New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isLive {
                        // Leaving keeps the session open; a separate Discard clears it.
                        Button("Close") { dismiss() }
                            .tint(Theme.accent)
                    } else {
                        Button(isEditing ? "Cancel" : "Discard", role: isEditing ? nil : .destructive) {
                            if !isEditing && draft.activities.isEmpty { dismiss() } else { showDiscardConfirm = true }
                        }
                        .tint(isEditing ? Theme.accent : .red)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Post") {
                        Task { await save() }
                    }
                    .disabled(
                        (draft.activities.isEmpty && draft.liveMatch == nil)
                            || store.isBusy
                            || isSubmitting
                    )
                }
            }
            .sheet(item: $editor) { route in
                switch route {
                case .newMatch:
                    ActivityEditorView(
                        activity: DraftActivity(carryingPlayersFrom: draft.activities.last)
                    ) { add($0); return true }
                case .edit(let activity):
                    ActivityEditorView(activity: activity) { update($0); return true }
                }
            }
            .sheet(isPresented: $showLocationPicker) {
                LocationPickerSheet(location: draftBinding.location)
            }
            .confirmationDialog(
                isEditing ? "Discard your changes?" : "Discard this session?",
                isPresented: $showDiscardConfirm,
                titleVisibility: .visible
            ) {
                Button(isEditing ? "Discard Changes" : "Discard Session", role: .destructive) {
                    if isLive {
                        // Suppress the external-success observer: this clear is
                        // an explicit discard, not a Watch-initiated post.
                        isSubmitting = true
                        store.discardLiveSession()
                    }
                    dismiss()
                }
                Button("Keep Editing", role: .cancel) {}
            }
        }
        .overlay {
            if showCelebration {
                CelebrationView(title: celebrationTitle)
                    .transition(.opacity)
            }
        }
        .interactiveDismissDisabled(!isLive && (isEditing || !draft.activities.isEmpty))
        .onAppear {
            store.errorMessage = nil
            if isLive, let activeDraft = store.activeDraft { localDraft = activeDraft }
        }
        .onChange(of: store.activeDraft) { oldValue, newValue in
            guard isLive else { return }
            if let newValue {
                // One-way snapshot only: never writes stale form state back into
                // the store, but preserves the last draft for external posting.
                localDraft = newValue
            } else if let oldValue, !isSubmitting, !showCelebration {
                // Watch-initiated posting bypasses save(), so the sheet itself
                // must react when the successful post clears the live draft.
                localDraft = oldValue
                Task { await finishExternalPost() }
            }
        }
        .alert(isEditing ? "Couldn't save session" : "Couldn't post session", isPresented: postErrorBinding) {
            Button("Cancel", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "Please try again.")
        }
    }

    private var postErrorBinding: Binding<Bool> {
        // Read the flag here rather than inside the getter: this property is
        // evaluated from `body`, so the read registers as an observation
        // dependency. A read deferred into the escaping closure would not.
        let hasError = store.errorMessage != nil
        return Binding(
            get: { hasError },
            set: { isPresented in
                if !isPresented { store.errorMessage = nil }
            }
        )
    }

    private var detailsCard: some View {
        VStack(spacing: 0) {
            if isEditing {
                DatePicker("Started", selection: draftBinding.startedAt)
                    .datePickerStyle(.compact)
                    .frame(minHeight: 44)
                Divider().overlay(Theme.hairline)
                DatePicker(
                    "Ended",
                    selection: Binding(
                        get: { draft.endedAt ?? draft.startedAt.addingTimeInterval(60) },
                        set: { draft.endedAt = max($0, draft.startedAt.addingTimeInterval(60)) }
                    ),
                    in: draft.startedAt.addingTimeInterval(60)...
                )
                .datePickerStyle(.compact)
                .frame(minHeight: 44)
            } else {
                HStack {
                    Label("In progress", systemImage: "clock")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                    Spacer()
                    TimelineView(.periodic(from: draft.startedAt, by: 1)) { _ in
                        Text(elapsed)
                            .font(.title3.weight(.bold).monospacedDigit())
                            .foregroundStyle(Theme.accent)
                    }
                }
                .frame(minHeight: 48)
            }
            Divider().overlay(Theme.hairline)
            TextField(AppStore.timeOfDayTitle(for: draft.startedAt), text: draftBinding.title)
                .font(.headline)
                .frame(minHeight: 44)
            Divider().overlay(Theme.hairline)
            Button {
                showLocationPicker = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "mappin.and.ellipse")
                        .foregroundStyle(Theme.accent)
                    Text(draft.location.isEmpty ? "Location" : draft.location)
                        .foregroundStyle(draft.location.isEmpty ? Theme.textTertiary : Theme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            Divider().overlay(Theme.hairline)
            TextField("Takeaway (optional)", text: draftBinding.takeaway, axis: .vertical)
                .lineLimit(1...3)
                .frame(minHeight: 44)
            Divider().overlay(Theme.hairline)
            photoRow
        }
        .padding(.horizontal, 16)
        .cardStyle(padding: 0)
        .onChange(of: selectedPhoto) { _, item in
            Task {
                draft.photoData = try? await item?.loadTransferable(type: Data.self)
                if draft.photoData != nil { draft.removePhoto = false }
            }
        }
    }

    @ViewBuilder
    private var photoRow: some View {
        if let data = draft.photoData, let image = UIImage(data: data) {
            HStack(spacing: 12) {
                Image(uiImage: image)
                    .resizable().scaledToFill()
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
                Text("Photo added").font(.subheadline).foregroundStyle(Theme.textPrimary)
                Spacer()
                Button { draft.photoData = nil; selectedPhoto = nil } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 8)
        } else if draft.existingPhotoPath != nil && !draft.removePhoto {
            HStack(spacing: 12) {
                Label("Current photo", systemImage: "photo")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button {
                    draft.removePhoto = true
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove photo")
            }
        } else {
            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                Label("Add a photo", systemImage: "photo.badge.plus")
                    .font(.subheadline)
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: 44)
            }
        }
    }

    private var addButtons: some View {
        AddActivityButton(title: "Match", systemImage: "flag.checkered") { editor = .newMatch }
    }

    private var activityList: some View {
        VStack(alignment: .leading, spacing: 12) {
            if draft.activities.isEmpty {
                Text("Add matches as you play. Post when you're done.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(draft.activities) { activity in
                    Button { editor = .edit(activity) } label: {
                        DraftActivityRow(activity: activity)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) { remove(activity) } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }

                Toggle("Post to feed", isOn: draftBinding.postToFeed)
                    .tint(Theme.accent)
                    .padding(.top, 4)
            }

            if isLive {
                Button(role: .destructive) {
                    showDiscardConfirm = true
                } label: {
                    Label("Discard session", systemImage: "trash")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .padding(.top, 8)
            }
        }
    }

    private var elapsed: String {
        let s = max(0, Int(Date().timeIntervalSince(draft.startedAt)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func add(_ activity: DraftActivity) { draft.activities.append(activity) }
    private func update(_ activity: DraftActivity) {
        if let i = draft.activities.firstIndex(where: { $0.id == activity.id }) { draft.activities[i] = activity }
    }
    private func remove(_ activity: DraftActivity) { draft.activities.removeAll { $0.id == activity.id } }

    /// `waitForWatch` is set only by the "Wait for Apple Watch" button on the
    /// gap prompt, so the finalization window is entered deliberately instead of
    /// being the default cost of every post.
    private func save() async {
        guard !isSubmitting else { return }

        isSubmitting = true
        defer { isSubmitting = false }

        if let existingSession {
            if await store.updateSession(existingSession, draft: draft) {
                Haptics.success()
                dismiss()
            }
        } else {
            let streakBefore = SessionStats(sessions: store.mySessions).weeklyStreak
            // Posting clears `store.activeDraft`; freeze what we sent so the
            // celebration overlay isn't drawn over an emptied-out sheet.
            localDraft = draft
            let posted = isLive
                ? await store.postLiveSession()
                : await store.postSession(draft)
            guard posted else { return }
            await finishSuccessfulPost(streakBefore: streakBefore)
        }
    }

    private func finishSuccessfulPost(streakBefore: Int) async {
        Haptics.success()
        if isLive { store.discardLiveSession() }
        // postSession reloaded mySessions — a milestone celebration only when
        // this post pushed the weekly streak onto a milestone.
        let streakAfter = SessionStats(sessions: store.mySessions).weeklyStreak
        let milestones: Set<Int> = [4, 12, 26, 52]
        celebrationTitle = (streakAfter > streakBefore && milestones.contains(streakAfter))
            ? "\(streakAfter)-week streak!"
            : "Session posted"
        withAnimation { showCelebration = true }
        try? await Task.sleep(nanoseconds: 1_050_000_000)
        dismiss()
    }

    private func finishExternalPost() async {
        Haptics.success()
        celebrationTitle = "Session posted"
        withAnimation { showCelebration = true }
        try? await Task.sleep(nanoseconds: 1_050_000_000)
        dismiss()
    }
}

enum ActivityEditorRoute: Identifiable {
    case newMatch, edit(DraftActivity)
    var id: String {
        switch self {
        case .newMatch: return "match"
        case .edit(let a): return a.id.uuidString
        }
    }
}

struct AddActivityButton: View {
    var title: String
    var systemImage: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage).font(.title2.weight(.semibold))
                Text(title).font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct DraftActivityRow: View {
    @Environment(AppStore.self) private var store
    var activity: DraftActivity

    private let avatarSize: CGFloat = 28

    var body: some View {
        matchScorecard.cardStyle()
    }

    private var matchScorecard: some View {
        MatchScorecardLayout(
            teamAvatars: teamAvatars,
            teamNames: teamNames,
            teamScore: activity.teamScore,
            teamAccent: teamAccent,
            opponentAvatars: opponentAvatars,
            opponentNames: opponentNames,
            opponentScore: activity.opponentScore,
            note: matchNote,
            noteLineLimit: 2
        )
    }

    private var teamAccent: Color? {
        activity.isTie ? nil : (activity.won ? Theme.win : Theme.loss)
    }

    private var teamAvatars: [ProfileAvatar] {
        let ownerAvatar = store.currentProfile.map {
            ProfileAvatar(profile: $0, size: avatarSize, unlinked: true)
        } ?? ProfileAvatar(preview: "Y", size: avatarSize)
        guard activity.matchFormat == .doubles else { return [ownerAvatar] }
        let partnerAvatar = playerAvatar(
            activity.partners.first,
            placeholderInitials: "P"
        )
        return [ownerAvatar, partnerAvatar]
    }

    private var opponentAvatars: [ProfileAvatar] {
        opponentSlots.enumerated().map { index, player in
            playerAvatar(
                player,
                placeholderInitials: activity.matchFormat == .singles ? "O" : "O\(index + 1)"
            )
        }
    }

    private var teamNames: String {
        let ownerName = store.currentProfile.map { shortName($0.displayName) } ?? "You"
        guard activity.matchFormat == .doubles else { return ownerName }
        let partnerName = activity.partners.first.map { shortName($0.displayName) } ?? "Partner"
        return "\(ownerName), \(partnerName)"
    }

    private var opponentNames: String {
        opponentSlots.enumerated().map { index, player in
            player.map { shortName($0.displayName) }
                ?? (activity.matchFormat == .singles ? "Opponent" : "Opponent \(index + 1)")
        }.joined(separator: ", ")
    }

    private var opponentSlots: [DraftPlayer?] {
        let selected = activity.opponents.prefix(activity.maxOpponents).map(Optional.some)
        return selected + Array(
            repeating: nil,
            count: activity.maxOpponents - selected.count
        )
    }

    private var matchNote: String? {
        let trimmed = activity.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func playerAvatar(_ player: DraftPlayer?, placeholderInitials: String) -> ProfileAvatar {
        guard let player else {
            return ProfileAvatar(preview: placeholderInitials, size: avatarSize)
        }
        if let profile = player.profile {
            return ProfileAvatar(profile: profile, size: avatarSize, unlinked: true)
        }
        return ProfileAvatar(guest: player.initials, size: avatarSize)
    }

    private func shortName(_ displayName: String) -> String {
        displayName.split(separator: " ").first.map(String.init) ?? displayName
    }
}
