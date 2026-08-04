import Foundation
import PhoneNumberKit

/// Country-aware display formatting and E.164 normalization for phone auth and
/// contact matching.
///
/// The dialing region is always an explicit parameter, never read from the
/// device. Reading it from the device is what sent an App Review sign-in to
/// `+86 555 555 0123`: the reviewer's device was China-region, so the demo
/// number typed without a country code parsed against CN metadata (`5555550123`
/// matches CN's general number pattern), missed the Supabase Test OTP entry for
/// `+1 555 555 0123`, and went to Twilio as a real SMS to China.
///
/// The lesson isn't "pick a better default" — it's that a region the user can't
/// see is a region they can't correct. Callers pass one that's on screen and
/// changeable (`PhoneNumberField`), and a typed `+` always wins over it.
enum PhoneNumberFormatting {
    private static let utility = PhoneNumberUtility()

    /// Where phone entry starts. The app is US-market, so the field opens on +1
    /// rather than guessing; the picker changes it for everyone else.
    static let defaultRegion = "US"

    /// Everything dialable, sorted by localized name, for the country picker.
    static let countries: [Country] = {
        utility.allCountries()
            .compactMap(Country.init(region:))
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }()

    private static let countriesByRegion: [String: Country] = Dictionary(
        uniqueKeysWithValues: countries.map { ($0.region, $0) }
    )

    /// One dialable country: what the picker lists and the field displays.
    struct Country: Identifiable, Hashable {
        /// ISO 3166-1 alpha-2, e.g. "US".
        let region: String
        let name: String
        let dialCode: UInt64

        var id: String { region }
        var dialCodeText: String { "+\(dialCode)" }

        init?(region: String) {
            // Two letters excludes "001" (non-geographic numbers), which has no
            // flag, no localized name, and nothing a user could pick it for.
            guard region.count == 2,
                  let dialCode = PhoneNumberFormatting.utility.countryCode(for: region),
                  let name = Locale.current.localizedString(forRegionCode: region)
            else { return nil }
            self.region = region
            self.name = name
            self.dialCode = dialCode
        }
    }

    static func country(for region: String) -> Country? {
        countriesByRegion[region]
    }

    /// A real number from `region`, in national format, for use as placeholder text.
    static func examplePlaceholder(for region: String) -> String {
        guard let example = utility.getExampleNumber(forCountry: region) else {
            return "Phone number"
        }
        return utility.format(example, toType: .national)
    }

    static func formatPartial(_ rawValue: String, region: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasInternationalPrefix = trimmed.hasPrefix("+") || trimmed.hasPrefix("＋")
        let digits = trimmed.filter(\.isNumber).prefix(15)

        guard !digits.isEmpty else {
            return hasInternationalPrefix ? "+" : ""
        }

        let sanitized = (hasInternationalPrefix ? "+" : "") + digits
        return partialFormatter(for: region).formatPartial(sanitized)
    }

    static func e164(_ rawValue: String, region: String = defaultRegion) -> String? {
        guard let number = parse(rawValue, region: region) else { return nil }
        return utility.format(number, toType: .e164)
    }

    /// The region an input names outright by carrying a `+` country code, so the
    /// picker can follow what was typed instead of sitting there contradicting
    /// it. Returns nil for national-format input, where the picker is the only
    /// thing that knows the country.
    static func explicitRegion(in rawValue: String, fallback: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("+") || trimmed.hasPrefix("＋") else { return nil }
        guard let regionID = parse(trimmed, region: fallback)?.regionID else { return nil }
        return countriesByRegion[regionID] != nil ? regionID : nil
    }

    private static func parse(_ rawValue: String, region: String) -> PhoneNumber? {
        // ignoreType: accept any plausibly-shaped number (right length, valid
        // dialing pattern) rather than only numbers assigned in the live
        // numbering plan. Unassigned ranges like 555 must work — the App Review
        // demo login (+1 555 555 0123, Supabase Test OTP) depends on it — and
        // the SMS provider is the real validator anyway.
        try? utility.parse(rawValue, withRegion: region, ignoreType: true)
    }

    /// A fresh formatter per call. `PartialFormatter` caches metadata for one
    /// region and mutates state as it formats, and the region now changes with
    /// the picker. Construction is cheap: it borrows its managers from the
    /// shared `PhoneNumberUtility`, which is the expensive object.
    private static func partialFormatter(for region: String) -> PartialFormatter {
        PartialFormatter(utility: utility, defaultRegion: region, withPrefix: true, maxDigits: 15)
    }
}
