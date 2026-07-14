import Contacts

/// Shared helper for reading the address book and normalizing phone numbers.
/// Used by onboarding (AuthView) and the in-app "Find Friends" sheet so both
/// go through one implementation.
enum ContactsImporter {
    private static let store = CNContactStore()

    /// Requests contacts access, returning whether it's granted. Never throws
    /// for a plain denial — only for an underlying system error.
    static func requestAccess() async throws -> Bool {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return try await withCheckedThrowingContinuation { continuation in
                store.requestAccess(for: .contacts) { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }
        @unknown default:
            return false
        }
    }

    /// Reads and normalizes every phone number in the address book (deduped).
    static func fetchPhones() throws -> [String] {
        let keys = [
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
            CNContactPhoneNumbersKey
        ] as [CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)
        var phones: Set<String> = []
        try store.enumerateContacts(with: request) { contact, _ in
            contact.phoneNumbers.forEach { number in
                if let normalized = normalizePhone(number.value.stringValue) {
                    phones.insert(normalized)
                }
            }
        }
        return Array(phones)
    }

    /// Normalizes a raw phone string to E.164-ish (`+1XXXXXXXXXX`). Returns nil
    /// for values that can't plausibly be a phone number.
    static func normalizePhone(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.filter(\.isNumber)
        guard digits.count >= 8, digits.count <= 15 else { return nil }
        if trimmed.hasPrefix("+") {
            return "+\(digits)"
        }
        if digits.count == 10 {
            return "+1\(digits)"
        }
        if digits.count == 11, digits.hasPrefix("1") {
            return "+\(digits)"
        }
        return "+\(digits)"
    }
}
