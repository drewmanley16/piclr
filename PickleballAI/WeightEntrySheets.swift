import SwiftUI

// MARK: - Log / edit a weigh-in

/// Which day the entry sheet was opened on. There is deliberately no separate
/// "new" vs "edit" mode: the sheet always edits *the selected day*, so moving
/// the date can never orphan the row it came from, and back-dating a missed
/// weigh-in is the same gesture as correcting today's.
struct WeightLogTarget: Identifiable {
    var day: Date

    var id: String { WeightEntry.string(from: day) }
}

struct WeightEntrySheet: View {
    let target: WeightLogTarget

    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store

    @State private var typed = ""
    @State private var day = Date()
    @State private var confirmsDelete = false
    @FocusState private var fieldFocused: Bool

    private var unit: WeightUnit { store.weightUnit }

    /// The weigh-in already stored on the selected day, if any.
    private var entryForDay: WeightEntry? {
        store.weightEntries.first { Calendar.current.isDate($0.day, inSameDayAs: day) }
    }

    private var isEditing: Bool { entryForDay != nil }

    /// The number the ± buttons start from when the field is still empty.
    private var fallbackPounds: Double? {
        entryForDay?.weightPounds ?? store.weightEntries.first?.weightPounds
    }

    private var enteredPounds: Double? {
        guard let value = Double(typed.replacingOccurrences(of: ",", with: ".")), value > 0 else { return nil }
        return unit.toPounds(value)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                entryField

                DatePicker("Date", selection: $day, in: ...Date(), displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .tint(Theme.accent)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 14)
                    .frame(height: 46)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))

                if let error = store.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(Theme.loss)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                saveButton

                if isEditing {
                    Button("Delete weigh-in", role: .destructive) { confirmsDelete = true }
                        .font(.subheadline.weight(.semibold))
                        .tint(Theme.loss)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .background(Theme.background)
            .navigationTitle(isEditing ? "Edit weigh-in" : "Log weight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear {
                store.errorMessage = nil
                day = target.day
                syncFieldToDay()
                fieldFocused = true
            }
            // Switching days re-points the sheet at that day's weigh-in, so the
            // field always shows what's actually stored for the date on screen.
            .onChange(of: day) { _, _ in syncFieldToDay() }
            .confirmationDialog("Delete this weigh-in?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    guard let existing = entryForDay else { return }
                    Haptics.warning()
                    Task {
                        await store.deleteWeightEntry(existing)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationBackground(Theme.background)
    }

    private var entryField: some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Spacer(minLength: 0)
                TextField(placeholder, text: $typed)
                    .keyboardType(.decimalPad)
                    .focused($fieldFocused)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 52, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize()
                Text(unit.label)
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                adjustButton(-0.2, icon: "minus")
                adjustButton(0.2, icon: "plus")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
    }

    private var placeholder: String {
        fallbackPounds.map { unit.display(pounds: $0) } ?? "0.0"
    }

    /// A day with no weigh-in starts empty on purpose: prefilling last week's
    /// number makes a blind tap record a weight that was never real. The last
    /// weight still shows as placeholder text and seeds the ± buttons.
    private func syncFieldToDay() {
        typed = entryForDay.map { unit.display(pounds: $0.weightPounds) } ?? ""
    }

    /// Nudges in display units, so a step feels the same size whichever unit
    /// the user is in.
    private func adjustButton(_ step: Double, icon: String) -> some View {
        Button {
            Haptics.tap()
            let current = Double(typed.replacingOccurrences(of: ",", with: "."))
                ?? fallbackPounds.map { unit.fromPounds($0) }
                ?? 0
            typed = String(format: "%.1f", max(0, current + step))
        } label: {
            Image(systemName: icon)
                .font(.subheadline.weight(.heavy))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 54, height: 34)
                .background(Theme.surfaceElevated, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var saveButton: some View {
        Button {
            guard let pounds = enteredPounds else { return }
            Task {
                if await store.logWeight(pounds: pounds, on: day) {
                    Haptics.success()
                    dismiss()
                }
            }
        } label: {
            Text(isEditing ? "Save changes" : "Save weigh-in")
                .font(.headline)
                .foregroundStyle(Theme.background)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(
                    enteredPounds == nil ? Theme.accent.opacity(0.35) : Theme.accent,
                    in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .disabled(enteredPounds == nil || store.isBusy)
    }
}

// MARK: - Goal weight

struct WeightGoalSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store

    @State private var typed = ""
    @FocusState private var fieldFocused: Bool

    private var unit: WeightUnit { store.weightUnit }

    private var enteredPounds: Double? {
        guard let value = Double(typed.replacingOccurrences(of: ",", with: ".")), value > 0 else { return nil }
        return unit.toPounds(value)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Spacer(minLength: 0)
                    TextField("0.0", text: $typed)
                        .keyboardType(.decimalPad)
                        .focused($fieldFocused)
                        .multilineTextAlignment(.trailing)
                        .font(.system(size: 52, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize()
                    Text(unit.label)
                        .font(.title3.weight(.heavy))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                )

                Text("Your goal draws a target line on the chart. Nobody else can see it.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)

                Button {
                    guard let pounds = enteredPounds else { return }
                    Haptics.success()
                    Task {
                        await store.setWeightGoal(pounds: pounds)
                        dismiss()
                    }
                } label: {
                    Text("Save goal")
                        .font(.headline)
                        .foregroundStyle(Theme.background)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(
                            enteredPounds == nil ? Theme.accent.opacity(0.35) : Theme.accent,
                            in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .disabled(enteredPounds == nil)

                if store.weightGoalPounds != nil {
                    Button("Remove goal", role: .destructive) {
                        Haptics.tap()
                        Task {
                            await store.setWeightGoal(pounds: nil)
                            dismiss()
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .tint(Theme.loss)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .background(Theme.background)
            .navigationTitle("Goal weight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear {
                if let goal = store.weightGoalPounds { typed = unit.display(pounds: goal) }
                fieldFocused = true
            }
        }
        .presentationDetents([.medium])
        .presentationBackground(Theme.background)
    }
}
