import SwiftUI

/// Name a new squad. Dismisses on success; the caller (`SquadsListSheet`)
/// re-navigates in via the refreshed `mySquads` list.
struct CreateSquadSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    @State private var name = ""

    private var isValid: Bool { (2...40).contains(name.trimmingCharacters(in: .whitespaces).count) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("SQUAD NAME")
                        .font(.caption2.weight(.bold))
                        .tracking(1)
                        .foregroundStyle(Theme.textTertiary)
                    TextField("e.g. Baseline Bashers", text: $name)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .padding(12)
                        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: Theme.radiusControl))
                }

                if let errorMessage = store.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(Theme.loss)
                }

                Spacer()
            }
            .padding(16)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("New Squad")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Haptics.impact()
                        Task {
                            if await store.createSquad(name: name) != nil {
                                dismiss()
                            }
                        }
                    }
                    .disabled(!isValid || store.isBusy)
                }
            }
        }
        .onAppear { store.errorMessage = nil }
    }
}
