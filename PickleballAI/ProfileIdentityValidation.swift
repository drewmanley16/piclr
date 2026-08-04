import Foundation
import SwiftUI

struct IdentityValidationResult: Equatable {
    let errorMessage: String?

    var isValid: Bool { errorMessage == nil }

    static let valid = IdentityValidationResult(errorMessage: nil)

    static func invalid(_ message: String) -> IdentityValidationResult {
        IdentityValidationResult(errorMessage: message)
    }
}

enum UsernameAvailability: Equatable {
    case idle
    case checking
    case available
    case taken
    case unavailable
}

enum IdentityFieldFeedback: Equatable {
    case none
    case checking
    case invalid(String)

    var message: String? {
        switch self {
        case .invalid(let message):
            return message
        case .none, .checking:
            return nil
        }
    }

    var color: Color {
        switch self {
        case .invalid:
            return .red
        case .none, .checking:
            return Theme.textSecondary
        }
    }
}

enum ProfileIdentityValidator {
    static let firstNameMaxLength = 30
    static let lastNameMaxLength = 40
    static let combinedNameMaxLength = 60
    static let usernameMinLength = 3
    static let usernameMaxLength = 24

    private static let allowedNamePunctuation = CharacterSet(charactersIn: " .-'’")

    static func firstName(_ value: String) -> IdentityValidationResult {
        validateName(value, label: "First name", maximumLength: firstNameMaxLength)
    }

    static func lastName(_ value: String) -> IdentityValidationResult {
        validateName(value, label: "Last name", maximumLength: lastNameMaxLength)
    }

    static func combinedName(firstName: String, lastName: String) -> IdentityValidationResult {
        let name = [normalizedName(firstName), normalizedName(lastName)]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard name.count <= combinedNameMaxLength else {
            return .invalid("First and last name can use up to \(combinedNameMaxLength) characters total")
        }
        return .valid
    }

    static func username(_ value: String) -> IdentityValidationResult {
        let username = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else {
            return .invalid("Username is required")
        }
        guard (usernameMinLength...usernameMaxLength).contains(username.count) else {
            return .invalid("Username must be \(usernameMinLength)–\(usernameMaxLength) characters")
        }
        guard username.unicodeScalars.allSatisfy(isAllowedUsernameScalar) else {
            return .invalid("Use only lowercase letters, numbers, periods, and underscores")
        }
        return .valid
    }

    static func normalizedName(_ value: String) -> String {
        value
            .precomposedStringWithCanonicalMapping
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func normalizedUsernameInput(_ value: String) -> String {
        value.lowercased()
    }

    static func suggestedUsername(firstName: String, lastName: String) -> String {
        let name = [normalizedName(firstName), normalizedName(lastName)]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        let suggestion = name
            .replacingOccurrences(of: " ", with: "_")
            .unicodeScalars
            .filter(isAllowedUsernameScalar)
            .map(String.init)
            .joined()

        return String(suggestion.prefix(usernameMaxLength))
            .trimmingCharacters(in: CharacterSet(charactersIn: "_."))
    }

    private static func validateName(
        _ value: String,
        label: String,
        maximumLength: Int
    ) -> IdentityValidationResult {
        let name = normalizedName(value)
        guard !name.isEmpty else {
            return .invalid("\(label) is required")
        }
        guard name.count <= maximumLength else {
            return .invalid("\(label) can use up to \(maximumLength) characters")
        }

        let scalars = name.unicodeScalars
        guard scalars.contains(where: CharacterSet.letters.contains) else {
            return .invalid("\(label) must include a letter")
        }
        guard scalars.allSatisfy({ scalar in
            CharacterSet.letters.contains(scalar)
                || CharacterSet.nonBaseCharacters.contains(scalar)
                || allowedNamePunctuation.contains(scalar)
        }) else {
            return .invalid("Use letters, spaces, apostrophes, hyphens, or periods")
        }
        return .valid
    }

    private static func isAllowedUsernameScalar(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 97 && scalar.value <= 122)
            || (scalar.value >= 48 && scalar.value <= 57)
            || scalar == "_"
            || scalar == "."
    }
}

struct IdentityInputField<Field: Hashable>: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    @FocusState.Binding var focusedField: Field?
    let field: Field
    var prefix: String?
    var textContentType: UITextContentType?
    var keyboard: UIKeyboardType = .default
    var autocapitalization: TextInputAutocapitalization = .words
    var autocorrectionDisabled = false
    var submitLabel: SubmitLabel = .next
    let feedback: IdentityFieldFeedback
    var onSubmit: () -> Void = {}

    private var isFocused: Bool { focusedField == field }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .tracking(0.6)
                .foregroundStyle(Theme.textSecondary)

            HStack(spacing: 8) {
                if let prefix {
                    Text(prefix)
                        .foregroundStyle(Theme.textSecondary)
                }

                TextField("", text: $text, prompt: prompt)
                    .keyboardType(keyboard)
                    .textInputAutocapitalization(autocapitalization)
                    .autocorrectionDisabled(autocorrectionDisabled)
                    .textContentType(textContentType)
                    .submitLabel(submitLabel)
                    .focused($focusedField, equals: field)
                    .onSubmit(onSubmit)
                    .accessibilityLabel(title)
                    .accessibilityHint(feedback.message ?? "")

                trailingIndicator
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 16)
            .frame(minHeight: 54)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: isFocused || isInvalid ? 1.5 : 1)
            )

            if let message = feedback.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(feedback.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var prompt: Text {
        Text(placeholder).foregroundStyle(Theme.textTertiary)
    }

    private var isInvalid: Bool {
        if case .invalid = feedback { return true }
        return false
    }

    private var borderColor: Color {
        if isInvalid { return .red.opacity(0.85) }
        if isFocused { return Theme.accent.opacity(0.85) }
        return Theme.hairline
    }

    @ViewBuilder
    private var trailingIndicator: some View {
        switch feedback {
        case .checking:
            ProgressView()
                .controlSize(.small)
                .tint(Theme.textSecondary)
                .accessibilityLabel("Checking")
        case .invalid:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Color.red)
                .accessibilityHidden(true)
        case .none:
            EmptyView()
        }
    }
}
