import SwiftUI

// MARK: - Measures

struct MeasuresSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store

    @State private var heightFeet = ""
    @State private var heightInches = ""
    @State private var weightPounds = ""
    @State private var shoeSize = ""

    private var totalHeightInches: Double? {
        guard !heightFeet.isEmpty || !heightInches.isEmpty else { return nil }
        return (Double(heightFeet) ?? 0) * 12 + (Double(heightInches) ?? 0)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Height") {
                    HStack {
                        TextField("Feet", text: $heightFeet)
                            .keyboardType(.numberPad)
                        Text("ft").foregroundStyle(Theme.textSecondary)
                        TextField("Inches", text: $heightInches)
                            .keyboardType(.decimalPad)
                        Text("in").foregroundStyle(Theme.textSecondary)
                    }
                }

                Section("Body & Fit") {
                    HStack {
                        TextField("Weight", text: $weightPounds)
                            .keyboardType(.decimalPad)
                        Text("lb").foregroundStyle(Theme.textSecondary)
                    }
                    HStack {
                        TextField("Shoe size", text: $shoeSize)
                            .keyboardType(.decimalPad)
                        Text("US").foregroundStyle(Theme.textSecondary)
                    }
                }

                Section {
                    Button {
                        Task {
                            let saved = await store.updateMeasures(
                                heightInches: totalHeightInches,
                                weightPounds: Double(weightPounds),
                                shoeSize: Double(shoeSize)
                            )
                            if saved { dismiss() }
                        }
                    } label: {
                        Text("Save Measures")
                            .font(.headline)
                            .foregroundStyle(Theme.background)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .disabled(store.isBusy)
                    .listRowBackground(Theme.accent)
                }

                if let error = store.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .listRowBackground(Theme.surface)
            .navigationTitle("Measures")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear {
                store.errorMessage = nil
                guard let profile = store.currentProfile else { return }
                if let total = profile.heightInches {
                    heightFeet = "\(Int(total) / 12)"
                    heightInches = String(format: "%g", total.truncatingRemainder(dividingBy: 12))
                }
                weightPounds = profile.weightPounds.map { String(format: "%g", $0) } ?? ""
                shoeSize = profile.shoeSize.map { String(format: "%g", $0) } ?? ""
            }
        }
    }
}
