import SwiftUI

/// Redeem a squad's join code to self-join. `prefilledCode` is set when opened
/// via a `pickleballai://squad/{code}` deep link, and auto-submits on appear.
struct JoinSquadSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    var prefilledCode: String? = nil
    @State private var code = ""
    @State private var joined = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("JOIN CODE")
                        .font(.caption2.weight(.bold))
                        .tracking(1)
                        .foregroundStyle(Theme.textTertiary)
                    TextField("e.g. ABCD234", text: $code)
                        .textFieldStyle(.plain)
                        .font(.title3.monospaced().weight(.semibold))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .padding(12)
                        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: Theme.radiusControl))
                }

                if joined {
                    Label("Joined!", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.win)
                } else if let errorMessage = store.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(Theme.loss)
                }

                Spacer()
            }
            .padding(16)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Join a Squad")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Join") { Task { await join() } }
                        .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || store.isBusy)
                }
            }
        }
        .onAppear {
            store.errorMessage = nil
            if let prefilledCode {
                code = prefilledCode
                Task { await join() }
            }
        }
    }

    private func join() async {
        Haptics.impact()
        if await store.redeemSquadCode(code) != nil {
            joined = true
            try? await Task.sleep(for: .milliseconds(500))
            dismiss()
        }
    }
}
