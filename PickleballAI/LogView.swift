import SwiftUI

// MARK: - Workout Tab

struct WorkoutView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showLog = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                logCTA

                VStack(alignment: .leading, spacing: 12) {
                    Text("Your Sessions")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)

                    if store.mySessions.isEmpty {
                        Text("No sessions yet — log your first one above.")
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
                HeaderCircleButton(systemImage: "plus", accessibilityTitle: "Log session") {
                    showLog = true
                }
            }
            .background(Theme.background)
        }
        .sheet(isPresented: $showLog) {
            LogView()
                .presentationDetents([.large])
        }
    }

    private var logCTA: some View {
        Button {
            showLog = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "figure.pickleball")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Theme.background)
                    .frame(width: 48, height: 48)
                    .background(Theme.accent, in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("Log a session")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Track today's play and share it")
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
    var session: FeedSession

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
                Text("\(session.durationMinutes) min · \(session.location ?? "—")")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()

            Text(session.date.relativeLabel)
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
        }
        .cardStyle()
    }
}

// MARK: - Log Session Form (sheet)

struct LogView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore

    @State private var title = ""
    @State private var location = ""
    @State private var durationMinutes = 90
    @State private var selectedFocus = SkillFocus.thirdShot
    @State private var takeaway = ""
    @State private var postToFeed = true

    var body: some View {
        NavigationStack {
            Form {
                Section("Session") {
                    TextField("Title (e.g. Chill dinks)", text: $title)
                    TextField("Location", text: $location)
                    Stepper("Duration: \(durationMinutes) min", value: $durationMinutes, in: 15...240, step: 5)
                    Picker("Focus", selection: $selectedFocus) {
                        ForEach(SkillFocus.allCases) { focus in
                            Text(focus.rawValue).tag(focus)
                        }
                    }
                }

                Section("Takeaway") {
                    TextField("What clicked today?", text: $takeaway, axis: .vertical)
                        .lineLimit(3...6)
                        .accessibilityLabel("Takeaway notes")
                }

                Section {
                    Toggle("Post to feed", isOn: $postToFeed)
                }

                Section {
                    Button {
                        Task {
                            await store.logSession(
                                title: title,
                                location: location,
                                durationMinutes: durationMinutes,
                                focus: selectedFocus.rawValue,
                                takeaway: takeaway,
                                postToFeed: postToFeed
                            )
                            dismiss()
                        }
                    } label: {
                        Label("Save Session", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                            .foregroundStyle(Theme.background)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .disabled(store.isBusy)
                    .listRowBackground(Theme.accent)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .listRowBackground(Theme.surface)
            .navigationTitle("Log Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
