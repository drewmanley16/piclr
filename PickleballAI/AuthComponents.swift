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
