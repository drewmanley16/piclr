import Foundation
import PhoneNumberKit

/// Country-aware display formatting and E.164 normalization for phone auth and
/// contact matching. Local input uses the device region; a leading `+` always
/// selects an explicit international calling code.
enum PhoneNumberFormatting {
    private static let utility = PhoneNumberUtility()
    private static let defaultRegion = PhoneNumberUtility.defaultRegionCode()
    private static let partialFormatter = PartialFormatter(
        utility: utility,
        defaultRegion: defaultRegion,
        withPrefix: true,
        maxDigits: 15
    )

    static let examplePlaceholder: String = {
        guard let example = utility.getExampleNumber(forCountry: defaultRegion) else {
            return "Phone number"
        }
        return utility.format(example, toType: .national)
    }()

    static func formatPartial(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasInternationalPrefix = trimmed.hasPrefix("+") || trimmed.hasPrefix("＋")
        let digits = trimmed.filter(\.isNumber).prefix(15)

        guard !digits.isEmpty else {
            return hasInternationalPrefix ? "+" : ""
        }

        let sanitized = (hasInternationalPrefix ? "+" : "") + digits
        return partialFormatter.formatPartial(sanitized)
    }

    static func e164(_ rawValue: String) -> String? {
        // ignoreType: accept any plausibly-shaped number (right length, valid
        // dialing pattern) rather than only numbers assigned in the live
        // numbering plan. Unassigned ranges like 555 must work — the App Review
        // demo login (+1 555 555 0123, Supabase Test OTP) depends on it — and
        // the SMS provider is the real validator anyway.
        guard let number = try? utility.parse(rawValue, withRegion: defaultRegion, ignoreType: true) else {
            return nil
        }
        return utility.format(number, toType: .e164)
    }
}
