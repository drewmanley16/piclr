import SwiftUI
import PhotosUI

// MARK: - Workout Tab

struct WorkoutView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showLiveSession = false
    @State private var quickEditor: ActivityEditorRoute?

    private var thisWeek: [FeedSession] {
        let weekStart = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        return store.mySessions.filter { $0.date >= weekStart }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if store.activeDraft != nil {
                    liveBanner
                } else {
                    weekStrip
                    startLiveButton
                    quickLog
                }
                recentSection
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Theme.background.ignoresSafeArea())
        .refreshable {
            if let uid = store.currentProfile?.id { await store.loadMySessions(userId: uid) }
        }
        .safeAreaInset(edge: .top) {
            AppHeader(title: "Play") {
                HeaderCircleButton(systemImage: "plus", accessibilityTitle: "Start session") {
                    startLive()
                }
            }
            .background(Theme.background)
        }
        .fullScreenCover(isPresented: $showLiveSession) {
            ActiveSessionView(isLive: true)
        }
        .sheet(item: $quickEditor) { route in
            switch route {
            case .newMatch:
                ActivityEditorView(activity: DraftActivity(kind: .match)) { activity in
                    Task { await store.quickLog(activity) }
                }
            case .newPractice:
                ActivityEditorView(activity: DraftActivity(kind: .practice)) { activity in
                    Task { await store.quickLog(activity) }
                }
            case .edit:
                EmptyView()
            }
        }
    }

    private func startLive() {
        store.startLiveSession()
        showLiveSession = true
    }

    // MARK: Live session banner

    private var liveBanner: some View {
        Button { showLiveSession = true } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Circle().fill(Theme.accent).frame(width: 10, height: 10)
                    Text("Session in progress")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    if let start = store.activeDraft?.startedAt {
                        TimelineView(.periodic(from: start, by: 1)) { _ in
                            Text(elapsed(since: start))
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }
                Text(liveSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                HStack {
                    Text("Tap to resume")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .cardStyle()
        }
        .buttonStyle(.plain)
    }

    private var liveSubtitle: String {
        let count = store.activeDraft?.activities.count ?? 0
        if count == 0 { return "No games logged yet — tap to add matches and practice." }
        return count == 1 ? "1 activity logged" : "\(count) activities logged"
    }

    private func elapsed(since start: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(start)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: This week

    private var weekStrip: some View {
        let hours = Double(thisWeek.reduce(0) { $0 + $1.durationMinutes }) / 60
        let streak = SessionStats(sessions: store.mySessions).streakLabel
        return HStack(spacing: 0) {
            weekStat("\(thisWeek.count)", "sessions")
            Divider().frame(height: 30).overlay(Theme.hairline)
            weekStat(String(format: "%.1f", hours), "hours")
            Divider().frame(height: 30).overlay(Theme.hairline)
            weekStat(streak, "streak")
        }
        .cardStyle()
    }

    private func weekStat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.title3.weight(.bold)).foregroundStyle(Theme.textPrimary)
            Text(label).font(.caption).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Quick log

    private var quickLog: some View {
        HStack(spacing: 12) {
            QuickLogButton(title: "Log a Match", systemImage: "flag.checkered", filled: true) {
                quickEditor = .newMatch
            }
            QuickLogButton(title: "Log Practice", systemImage: "figure.cooldown", filled: false) {
                quickEditor = .newPractice
            }
        }
    }

    private var startLiveButton: some View {
        Button { startLive() } label: {
            HStack(spacing: 16) {
                Image(systemName: "play.fill")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Theme.background)
                    .frame(width: 56, height: 56)
                    .background(Theme.accent, in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text("Start a live session")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Log matches and practice as you play")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.body.weight(.bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Recent

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            if store.mySessions.isEmpty {
                Text("No sessions yet — log a match or start a session above.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(store.mySessions.prefix(10)) { session in
                    SessionSummaryRow(session: session)
                }
            }
        }
    }
}

struct QuickLogButton: View {
    let title: String
    let systemImage: String
    let filled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(filled ? Theme.background : Theme.accent)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(filled ? Theme.background : Theme.textPrimary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .frame(height: 104, alignment: .topLeading)
            .background(filled ? Theme.accent : Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(Theme.accent)
                .frame(width: 46, height: 46)
                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 13, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(session.displayTitle)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                if session.matchCount > 0 {
                    let r = matchResults
                    Text("\(r.wins)–\(r.losses)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(r.wins >= r.losses ? Theme.accent : Theme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            r.wins >= r.losses ? Theme.accentSoft : Theme.surfaceElevated,
                            in: Capsule()
                        )
                }
                Text(session.date.relativeLabel)
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }

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
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 28, height: 40)
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

    private var icon: String {
        if session.matchCount > 0 && session.practiceCount == 0 { return "flag.checkered" }
        if session.practiceCount > 0 && session.matchCount == 0 { return "figure.cooldown" }
        return "figure.pickleball"
    }

    private var matchResults: (wins: Int, losses: Int) {
        var wins = 0, losses = 0
        for activity in session.sortedActivities where activity.isMatch {
            if let won = activity.won { won ? (wins += 1) : (losses += 1) }
        }
        return (wins, losses)
    }

    private var subtitle: String {
        var parts: [String] = []
        if session.matchCount > 0 { parts.append("\(session.matchCount) match\(session.matchCount == 1 ? "" : "es")") }
        if session.practiceCount > 0 { parts.append("\(session.practiceCount) practice") }
        if session.durationMinutes > 1 { parts.append("\(session.durationMinutes) min") }
        if parts.isEmpty { parts.append("Session") }
        return parts.joined(separator: " · ")
    }
}

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
        } else if await store.postSession(draft) {
            Haptics.success()
            if isLive { store.discardLiveSession() }
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
