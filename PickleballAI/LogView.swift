import SwiftUI

struct LogView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    var isPresentedAsSheet = false

    @State private var selectedLogType = LogType.match
    @State private var location = "Riverside Courts"
    @State private var teamOneScore = 11
    @State private var teamTwoScore = 8
    @State private var selectedFocus = SkillFocus.thirdShot
    @State private var notes = ""
    @State private var durationMinutes = 90
    @State private var selectedDrills: Set<String> = ["Third-shot drops", "Cross-court dinks"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Log Type", selection: $selectedLogType) {
                        ForEach(LogType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                switch selectedLogType {
                case .match:
                    matchFields
                case .session:
                    sessionFields
                }

                Section("Takeaway") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 92)
                        .accessibilityLabel("Takeaway notes")
                }

                Section {
                    Button {
                        dismiss()
                    } label: {
                        Label("Save Log", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle("Log")
            .navigationBarTitleDisplayMode(isPresentedAsSheet ? .inline : .large)
            .toolbar {
                if isPresentedAsSheet {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    private var matchFields: some View {
        Group {
            Section("Match") {
                TextField("Location", text: $location)
                Picker("Focus", selection: $selectedFocus) {
                    ForEach(SkillFocus.allCases) { focus in
                        Text(focus.rawValue).tag(focus)
                    }
                }
                Stepper("Team 1 Score: \(teamOneScore)", value: $teamOneScore, in: 0...30)
                Stepper("Team 2 Score: \(teamTwoScore)", value: $teamTwoScore, in: 0...30)
            }

            Section("Players") {
                PlayerPickerRow(title: "My Partner", player: store.players[safe: 1])
                PlayerPickerRow(title: "Opponent 1", player: store.players[safe: 2])
                PlayerPickerRow(title: "Opponent 2", player: store.players[safe: 3])
            }

            Section("Visibility") {
                Toggle("Post to group feed", isOn: .constant(true))
                Toggle("Ask tagged players to confirm", isOn: .constant(true))
            }
        }
    }

    private var sessionFields: some View {
        Group {
            Section("Session") {
                TextField("Location", text: $location)
                Stepper("Duration: \(durationMinutes) min", value: $durationMinutes, in: 15...240, step: 5)
                Picker("Main Focus", selection: $selectedFocus) {
                    ForEach(SkillFocus.allCases) { focus in
                        Text(focus.rawValue).tag(focus)
                    }
                }
            }

            Section("Drills") {
                ForEach(Self.drillOptions, id: \.self) { drill in
                    Button {
                        toggle(drill)
                    } label: {
                        HStack {
                            Text(drill)
                                .foregroundStyle(.primary)
                            Spacer()
                            if selectedDrills.contains(drill) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.teal)
                            }
                        }
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(selectedDrills.contains(drill) ? "Remove" : "Add") \(drill)")
                }
            }

            Section("Played Today") {
                Stepper("Matches: 5", value: .constant(5), in: 0...20)
                Stepper("Wins: 3", value: .constant(3), in: 0...20)
            }
        }
    }

    private func toggle(_ drill: String) {
        if selectedDrills.contains(drill) {
            selectedDrills.remove(drill)
        } else {
            selectedDrills.insert(drill)
        }
    }

    private static let drillOptions = [
        "Deep serves",
        "Return depth",
        "Third-shot drops",
        "Cross-court dinks",
        "Transition resets",
        "Kitchen hands",
        "Middle communication"
    ]
}

struct PlayerPickerRow: View {
    var title: String
    var player: Player?

    var body: some View {
        HStack(spacing: 12) {
            if let player {
                AvatarView(initials: player.avatarInitials)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(player.name)
                        .font(.body)
                }
            } else {
                Text(title)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: 44)
    }
}

enum LogType: String, CaseIterable, Identifiable {
    case match = "Match"
    case session = "Session"

    var id: String { rawValue }
}

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

