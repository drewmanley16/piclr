import SwiftUI
import PhotosUI

// MARK: - Workout Tab

struct WorkoutView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showSession = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                startCTA

                VStack(alignment: .leading, spacing: 12) {
                    Text("Your Sessions")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)

                    if store.mySessions.isEmpty {
                        Text("No sessions yet — start one above.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(store.mySessions) { session in
                            SessionSummaryRow(session: session)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Theme.background.ignoresSafeArea())
        .refreshable {
            if let uid = store.currentProfile?.id { await store.loadMySessions(userId: uid) }
        }
        .safeAreaInset(edge: .top) {
            AppHeader(title: "Workout") {
                HeaderCircleButton(systemImage: "plus", accessibilityTitle: "Start session") {
                    showSession = true
                }
            }
            .background(Theme.background)
        }
        .fullScreenCover(isPresented: $showSession) {
            ActiveSessionView()
        }
    }

    private var startCTA: some View {
        Button {
            showSession = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "play.fill")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Theme.background)
                    .frame(width: 48, height: 48)
                    .background(Theme.accent, in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("Start a session")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Log practices and matches as you play")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .cardStyle()
        }
        .buttonStyle(.plain)
    }
}

struct SessionSummaryRow: View {
    @EnvironmentObject private var store: AppStore
    var session: FeedSession
    @State private var showEditor = false
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "figure.pickleball")
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
                .background(Theme.accentSoft, in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(session.displayTitle)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(session.date.relativeLabel)
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)

            Menu {
                Button {
                    showEditor = true
                } label: {
                    Label("Edit Session", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("Delete Session", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("Session actions")
        }
        .cardStyle()
        .fullScreenCover(isPresented: $showEditor) {
            ActiveSessionView(existingSession: session)
        }
        .confirmationDialog("Delete this session?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Session", role: .destructive) {
                Task { _ = await store.deleteSession(session) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Matches, practices, comments, and likes on this post will be removed.")
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if session.matchCount > 0 { parts.append("\(session.matchCount) match\(session.matchCount == 1 ? "" : "es")") }
        if session.practiceCount > 0 { parts.append("\(session.practiceCount) practice") }
        parts.append("\(session.durationMinutes) min")
        return parts.joined(separator: " · ")
    }
}

// MARK: - Active session (live builder)

struct ActiveSessionView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore

    let existingSession: FeedSession?

    @State private var draft: SessionDraft
    @State private var editor: ActivityEditorRoute?
    @State private var showDiscardConfirm = false
    @State private var selectedPhoto: PhotosPickerItem?

    init(existingSession: FeedSession? = nil) {
        self.existingSession = existingSession
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
                    Button(isEditing ? "Cancel" : "Discard", role: isEditing ? nil : .destructive) {
                        if !isEditing && draft.activities.isEmpty { dismiss() } else { showDiscardConfirm = true }
                    }
                    .tint(isEditing ? Theme.accent : .red)
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
            .confirmationDialog(
                isEditing ? "Discard your changes?" : "Discard this session?",
                isPresented: $showDiscardConfirm,
                titleVisibility: .visible
            ) {
                Button(isEditing ? "Discard Changes" : "Discard Session", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            }
        }
        .interactiveDismissDisabled(isEditing || !draft.activities.isEmpty)
        .onAppear { store.errorMessage = nil }
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
            TextField("Session title (optional)", text: $draft.title)
                .font(.headline)
                .frame(minHeight: 44)
            Divider().overlay(Theme.hairline)
            TextField("Location", text: $draft.location)
                .frame(minHeight: 44)
            Divider().overlay(Theme.hairline)
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
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    TimelineView(.periodic(from: draft.startedAt, by: 1)) { _ in
                        Text(elapsed)
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Theme.accent)
                    }
                }
                .frame(minHeight: 44)
            }
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
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
            if await store.updateSession(existingSession, draft: draft) { dismiss() }
        } else if await store.postSession(draft) {
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
            return names.isEmpty ? (activity.won ? "Won" : "Lost") : names.joined(separator: ", ")
        }
    }
}
