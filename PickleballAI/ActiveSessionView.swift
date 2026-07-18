import SwiftUI
import PhotosUI

// MARK: - Active session (live builder)

struct ActiveSessionView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore

    let existingSession: FeedSession?
    /// When true, this is the persistent "live" session — changes sync back to
    /// store.activeDraft so it survives leaving the tab, and the sheet can be
    /// dismissed freely to resume later.
    let isLive: Bool

    @State private var draft: SessionDraft
    @State private var editor: ActivityEditorRoute?
    @State private var showDiscardConfirm = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showLocationPicker = false
    @State private var showCelebration = false
    @State private var celebrationTitle = "Session posted"

    init(existingSession: FeedSession? = nil, isLive: Bool = false) {
        self.existingSession = existingSession
        self.isLive = isLive
        _draft = State(initialValue: existingSession.map(SessionDraft.init(session:)) ?? SessionDraft())
    }

    private var isEditing: Bool { existingSession != nil }

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
                    Button(isEditing ? "Save" : "Post") { Task { await save() } }
                        .disabled(draft.activities.isEmpty || store.isBusy)
                }
            }
            .sheet(item: $editor) { route in
                switch route {
                case .newPractice:
                    ActivityEditorView(activity: DraftActivity(kind: .practice)) { add($0) }
                case .newMatch:
                    ActivityEditorView(activity: DraftActivity(kind: .match)) { add($0) }
                case .edit(let activity):
                    ActivityEditorView(activity: activity) { update($0) }
                }
            }
            .sheet(isPresented: $showLocationPicker) {
                LocationPickerSheet(location: $draft.location)
            }
            .confirmationDialog(
                isEditing ? "Discard your changes?" : "Discard this session?",
                isPresented: $showDiscardConfirm,
                titleVisibility: .visible
            ) {
                Button(isEditing ? "Discard Changes" : "Discard Session", role: .destructive) {
                    if isLive { store.discardLiveSession() }
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
            if isLive, let live = store.activeDraft { draft = live }
        }
        .onChange(of: draft) { _, newValue in
            if isLive { store.activeDraft = newValue }
        }
        .alert(isEditing ? "Couldn't save session" : "Couldn't post session", isPresented: postErrorBinding) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "Please try again.")
        }
    }

    private var postErrorBinding: Binding<Bool> {
        Binding(
            get: { store.errorMessage != nil },
            set: { isPresented in
                if !isPresented { store.errorMessage = nil }
            }
        )
    }

    private var detailsCard: some View {
        VStack(spacing: 0) {
            if isEditing {
                DatePicker("Started", selection: $draft.startedAt)
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
            TextField(AppStore.timeOfDayTitle(for: draft.startedAt), text: $draft.title)
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
            TextField("Takeaway (optional)", text: $draft.takeaway, axis: .vertical)
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
        HStack(spacing: 12) {
            AddActivityButton(title: "Practice", systemImage: "figure.cooldown") { editor = .newPractice }
            AddActivityButton(title: "Match", systemImage: "flag.checkered") { editor = .newMatch }
        }
    }

    private var activityList: some View {
        VStack(alignment: .leading, spacing: 12) {
            if draft.activities.isEmpty {
                Text("Add practices and matches as you play. Post when you're done.")
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

                Toggle("Post to feed", isOn: $draft.postToFeed)
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

    private func save() async {
        if let existingSession {
            if await store.updateSession(existingSession, draft: draft) {
                Haptics.success()
                dismiss()
            }
        } else {
            let streakBefore = SessionStats(sessions: store.mySessions).weeklyStreak
            guard await store.postSession(draft) else { return }
            Haptics.success()
            if isLive { store.discardLiveSession() }
            // postSession reloaded mySessions — a milestone celebration only when
            // this post pushed the weekly streak onto a milestone.
            let streakAfter = SessionStats(sessions: store.mySessions).weeklyStreak
            let milestones: Set<Int> = [4, 12, 26, 52]
            celebrationTitle = (streakAfter > streakBefore && milestones.contains(streakAfter))
                ? "🔥 \(streakAfter)-week streak!"
                : "Session posted"
            withAnimation { showCelebration = true }
            try? await Task.sleep(nanoseconds: 1_050_000_000)
            dismiss()
        }
    }
}

enum ActivityEditorRoute: Identifiable {
    case newPractice, newMatch, edit(DraftActivity)
    var id: String {
        switch self {
        case .newPractice: return "practice"
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
    var activity: DraftActivity

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: activity.kind == .match ? "flag.checkered" : "figure.cooldown")
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
                .background(Theme.accentSoft, in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(activity.summary)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                if let detail { Text(detail).font(.subheadline).foregroundStyle(Theme.textSecondary).lineLimit(1) }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.textTertiary)
        }
        .cardStyle()
    }

    private var detail: String? {
        switch activity.kind {
        case .practice:
            return activity.reps.isEmpty ? (activity.notes.isEmpty ? nil : activity.notes) : activity.reps
        case .match:
            let names = (activity.partners + activity.opponents).map(\.displayName)
            let outcome = activity.isTie ? "Tied" : (activity.won ? "Won" : "Lost")
            return names.isEmpty ? outcome : names.joined(separator: ", ")
        }
    }
}
