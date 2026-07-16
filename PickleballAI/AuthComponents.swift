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
        Text(placeholder).foregroundColor(Theme.textTertiary)
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
