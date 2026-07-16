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

    /// Normalizes a valid local or international phone number to E.164.
    static func normalizePhone(_ value: String) -> String? {
        PhoneNumberFormatting.e164(value)
    }
}
