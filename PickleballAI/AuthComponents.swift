import SwiftUI

struct SkillLevelButton: View {
    var level: SkillLevel
    @Binding var selectedLevel: SkillLevel

    var body: some View {
        Button {
            selectedLevel = level
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selectedLevel == level ? "checkmark.circle.fill" : "circle")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(selectedLevel == level ? Theme.accent : Theme.textTertiary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(level.title)
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text(level.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            }
            .cardStyle(fill: selectedLevel == level ? Theme.surfaceElevated : Theme.surface)
        }
        .buttonStyle(.plain)
    }
}

struct AuthField: View {
    var placeholder: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default
    var autocapitalize: Bool = true
    var secure: Bool = false
    var textContentType: UITextContentType?

    var body: some View {
        Group {
            if secure {
                SecureField("", text: $text, prompt: prompt)
            } else {
                TextField("", text: $text, prompt: prompt)
                    .keyboardType(keyboard)
                    .textInputAutocapitalization(autocapitalize ? .words : .never)
                    .autocorrectionDisabled(!autocapitalize)
                    .textContentType(textContentType)
            }
        }
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }

    private var prompt: Text {
        Text(placeholder).foregroundStyle(Theme.textTertiary)
    }
}

/// Phone entry with the dialing country spelled out beside the number.
///
/// The country chip is the point of this control, not decoration: it's what
/// makes a wrong country a thing the user can see and fix rather than a silent
/// misroute of their verification SMS (see `PhoneNumberFormatting`).
struct PhoneNumberField: View {
    @Binding var region: String
    @Binding var text: String

    @State private var isPickingCountry = false

    var body: some View {
        HStack(spacing: 0) {
            countryButton

            Rectangle()
                .fill(Theme.hairline)
                .frame(width: 1, height: 26)

            TextField("", text: $text, prompt: prompt)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 14)
                .frame(height: 52)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
        .sheet(isPresented: $isPickingCountry) {
            CountryPickerSheet(region: $region)
        }
    }

    private var countryButton: some View {
        Button {
            Haptics.tap()
            isPickingCountry = true
        } label: {
            // Country code as letters, not a flag: the simulator has no glyphs
            // for regional-indicator flag sequences, and this is the one control
            // that must never render as a pair of empty boxes. "US" also
            // disambiguates the countries that share a dialing code (+1 is US
            // and Canada both).
            HStack(spacing: 6) {
                Text(region)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                Text(country?.dialCodeText ?? "+")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Country calling code")
        .accessibilityValue(country.map { "\($0.name), \($0.dialCodeText)" } ?? "Not set")
    }

    private var country: PhoneNumberFormatting.Country? {
        PhoneNumberFormatting.country(for: region)
    }

    private var prompt: Text {
        Text(PhoneNumberFormatting.examplePlaceholder(for: region))
            .foregroundStyle(Theme.textTertiary)
    }
}

/// Country list for `PhoneNumberField`. Static data, so there's nothing to load
/// or refresh — the only empty state it can reach is a search that matched
/// nothing.
struct CountryPickerSheet: View {
    @Binding var region: String

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            Group {
                if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    countryList
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Country")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Country or code")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.accent)
                }
            }
        }
    }

    private var countryList: some View {
        List(results) { country in
            Button {
                Haptics.tap()
                region = country.region
                dismiss()
            } label: {
                HStack(spacing: 12) {
                    Text(country.region)
                        .font(.footnote.weight(.semibold).monospaced())
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 28, alignment: .leading)
                    Text(country.name)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(country.dialCodeText)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Theme.accent)
                        .opacity(country.region == region ? 1 : 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(Theme.surface)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var results: [PhoneNumberFormatting.Country] {
        let needle = query.trimmed
        guard !needle.isEmpty else { return PhoneNumberFormatting.countries }
        return PhoneNumberFormatting.countries.filter {
            $0.name.localizedCaseInsensitiveContains(needle)
                || $0.dialCodeText.contains(needle)
                || $0.region.localizedCaseInsensitiveCompare(needle) == .orderedSame
        }
    }
}

struct OTPCodeField: View {
    @Binding var code: String
    @FocusState private var isFocused: Bool

    private let digitCount = 6

    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                ForEach(0..<digitCount, id: \.self) { index in
                    Text(digit(at: index))
                        .font(.title2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(
                            Theme.surface,
                            in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                                .strokeBorder(borderColor(at: index), lineWidth: isActive(index) ? 1.5 : 1)
                        }
                }
            }
            .accessibilityHidden(true)

            TextField("", text: sanitizedCode)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($isFocused)
                .foregroundStyle(Color.clear)
                .tint(Color.clear)
                .accessibilityLabel("Six-digit verification code")
                .accessibilityValue("\(code.count) of \(digitCount) digits entered")
        }
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
        .onAppear { isFocused = true }
        .animation(.easeOut(duration: 0.15), value: code.count)
    }

    private var sanitizedCode: Binding<String> {
        Binding(
            get: { code },
            set: { code = String($0.filter(\.isNumber).prefix(digitCount)) }
        )
    }

    private func digit(at index: Int) -> String {
        guard index < code.count else { return "" }
        let codeIndex = code.index(code.startIndex, offsetBy: index)
        return String(code[codeIndex])
    }

    private func isActive(_ index: Int) -> Bool {
        guard isFocused else { return false }
        return index == min(code.count, digitCount - 1)
    }

    private func borderColor(at index: Int) -> Color {
        isActive(index) ? Theme.accent.opacity(0.85) : Theme.hairline
    }
}
