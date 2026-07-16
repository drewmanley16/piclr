import SwiftUI

/// Central home for the hosted legal documents. These URLs MUST resolve to the
/// live Terms of Use — which has to carry an explicit zero-tolerance clause for
/// objectionable content and abusive users (App Store Review Guideline 1.2) —
/// and the Privacy Policy before submitting to App Review.
enum Legal {
    static let termsURL = "https://pickleball-ai-web.vercel.app/terms"
    static let privacyURL = "https://pickleball-ai-web.vercel.app/privacy"
}

/// Shared app links used in more than one screen.
enum AppLinks {
    /// Destination of "Share invite link". Pre-launch this is the marketing site
    /// (waitlist + "coming soon"), so shared invites always land somewhere real.
    // TODO: swap to App Store URL at launch
    static let invite = "https://pickleball-ai-web.vercel.app"
}

struct AuthView: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("hasSeenOnboardingSplash") private var hasSeenOnboardingSplash = false

    enum Step {
        case splash
        case phone
        case code
        case profile
        case skill
        case friends
    }

    private enum ProfileField: Hashable {
        case firstName
        case lastName
        case username
    }

    let startsAtProfile: Bool

    @State private var step: Step
    @State private var didInitialize = false
    @State private var phone = ""
    @State private var verifiedPhone = ""
    @State private var code = ""
    @State private var firstName = ""
    @State private var lastName = ""
    @State private var username = ""
    @State private var didEditUsername = false
    @State private var touchedProfileFields: Set<ProfileField> = []
    @State private var usernameAvailability = UsernameAvailability.idle
    @FocusState private var focusedProfileField: ProfileField?
    @State private var selectedSkill = SkillLevel.intermediate
    @State private var duprRating = ""
    @State private var searchQuery = ""
    @State private var contactStatus: String?
    @State private var agreedToTerms = false

    init(startsAtProfile: Bool = false) {
        self.startsAtProfile = startsAtProfile
        _step = State(initialValue: startsAtProfile ? .profile : .splash)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                content
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.background.ignoresSafeArea())
        .onAppear(perform: initialize)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .splash:
            splashStep
        case .phone:
            phoneStep
        case .code:
            codeStep
        case .profile:
            profileStep
        case .skill:
            skillStep
        case .friends:
            friendsStep
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "figure.pickleball")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Theme.background)
                    .frame(width: 44, height: 44)
                    .background(Theme.accent, in: Circle())
                Text("pickleball.ai")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
            }

            Text(title)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 44)
    }

    private var splashStep: some View {
        VStack(spacing: 20) {
            OnboardingPreviewCard()

            primaryButton("Get Started", systemImage: "arrow.right") {
                hasSeenOnboardingSplash = true
                step = .phone
            }

            Button {
                hasSeenOnboardingSplash = true
                step = .phone
            } label: {
                Text("Skip")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
        }
    }

    private var phoneStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            AuthField(
                placeholder: PhoneNumberFormatting.examplePlaceholder,
                text: $phone,
                keyboard: .phonePad,
                autocapitalize: false,
                textContentType: .telephoneNumber
            )
            .onChange(of: phone) { _, newValue in
                let formatted = Self.formattedPhoneInput(newValue)
                if formatted != phone {
                    phone = formatted
                }
            }

            errorText

            termsGate

            primaryButton("Send Code", systemImage: "message.fill", disabled: normalizedPhone == nil || !agreedToTerms) {
                guard let normalizedPhone else { return }
                Task {
                    if await store.sendPhoneOTP(phone: normalizedPhone) {
                        verifiedPhone = normalizedPhone
                        step = .code
                    }
                }
            }
        }
    }

    private static func formattedPhoneInput(_ raw: String) -> String {
        PhoneNumberFormatting.formatPartial(raw)
    }

    private var codeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            OTPCodeField(code: $code)

            HStack {
                Text(PhoneNumberFormatting.formatPartial(verifiedPhone))
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button("Change") {
                    code = ""
                    step = .phone
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.accent)
            }

            errorText

            primaryButton("Verify", systemImage: "checkmark.circle.fill", disabled: codeDigits.count != 6) {
                Task {
                    _ = await store.verifyPhoneOTP(phone: verifiedPhone, token: codeDigits)
                }
            }

            Button {
                Task { _ = await store.sendPhoneOTP(phone: verifiedPhone) }
            } label: {
                Text("Resend code")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
            .disabled(store.isBusy || verifiedPhone.isEmpty)
        }
    }

    private var profileStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Text(profileInitials)
                    .font(.title.weight(.bold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 68, height: 68)
                    .background(Theme.surfaceElevated, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Default avatar")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text("You can add a photo later.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            HStack(alignment: .top, spacing: 12) {
                IdentityInputField(
                    title: "First name",
                    placeholder: "",
                    text: $firstName,
                    focusedField: $focusedProfileField,
                    field: .firstName,
                    textContentType: .givenName,
                    feedback: firstNameFeedback,
                    onSubmit: { focusedProfileField = .lastName }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: firstName) { _, _ in
                    guard !didEditUsername else { return }
                    username = ProfileIdentityValidator.suggestedUsername(firstName: firstName, lastName: lastName)
                }

                IdentityInputField(
                    title: "Last name",
                    placeholder: "",
                    text: $lastName,
                    focusedField: $focusedProfileField,
                    field: .lastName,
                    textContentType: .familyName,
                    feedback: lastNameFeedback,
                    onSubmit: { focusedProfileField = .username }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: lastName) { _, _ in
                    guard !didEditUsername else { return }
                    username = ProfileIdentityValidator.suggestedUsername(firstName: firstName, lastName: lastName)
                }
            }

            IdentityInputField(
                title: "Username",
                placeholder: "",
                text: $username,
                focusedField: $focusedProfileField,
                field: .username,
                prefix: "@",
                textContentType: .username,
                keyboard: .asciiCapable,
                autocapitalization: .never,
                autocorrectionDisabled: true,
                submitLabel: .done,
                feedback: usernameFeedback,
                onSubmit: { focusedProfileField = nil }
            )
            .onChange(of: username) { _, newValue in
                let normalized = ProfileIdentityValidator.normalizedUsernameInput(newValue)
                if normalized != newValue {
                    username = normalized
                    return
                }
                usernameAvailability = .idle
                if newValue != ProfileIdentityValidator.suggestedUsername(firstName: firstName, lastName: lastName) {
                    didEditUsername = true
                }
            }
            .task(id: username) {
                await checkUsernameAvailability()
            }

            primaryButton("Continue", systemImage: "arrow.right", disabled: !profileIsValid) {
                firstName = ProfileIdentityValidator.normalizedName(firstName)
                lastName = ProfileIdentityValidator.normalizedName(lastName)
                username = username.trimmingCharacters(in: .whitespacesAndNewlines)
                focusedProfileField = nil
                step = .skill
            }
        }
        .onChange(of: focusedProfileField) { oldField, _ in
            guard let oldField else { return }
            touchedProfileFields.insert(oldField)
            switch oldField {
            case .firstName:
                firstName = ProfileIdentityValidator.normalizedName(firstName)
            case .lastName:
                lastName = ProfileIdentityValidator.normalizedName(lastName)
            case .username:
                username = username.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    private var skillStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(SkillLevel.allCases) { level in
                SkillLevelButton(level: level, selectedLevel: $selectedSkill)
            }

            if selectedSkill == .dupr {
                AuthField(
                    placeholder: "DUPR rating",
                    text: $duprRating,
                    keyboard: .decimalPad,
                    autocapitalize: false
                )
                Text("Use a number from 2.00 to 8.00.")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }

            primaryButton("Continue", systemImage: "arrow.right", disabled: !skillIsValid) {
                step = .friends
            }
        }
    }

    private var friendsStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    Task { await syncContacts() }
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Theme.background)
                            .frame(width: 44, height: 44)
                            .background(Theme.accent, in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Find friends already using pickleball.ai")
                                .font(.headline)
                                .foregroundStyle(Theme.textPrimary)
                            Text("Contacts are matched once and not stored.")
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                    }
                    .cardStyle()
                }
                .buttonStyle(.plain)
                .disabled(store.isBusy)

                if let contactStatus {
                    Text(contactStatus)
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            if !store.contactMatches.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("From contacts")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    ForEach(store.contactMatches) { match in
                        FriendCandidateRow(profile: match.profile)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Search name or username")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                AuthField(
                    placeholder: "Name or @username",
                    text: $searchQuery,
                    autocapitalize: false,
                    textContentType: .username
                )
                .task(id: searchQuery) {
                    await store.searchProfilesAfterTyping(query: searchQuery)
                }

                ForEach(store.searchResults) { profile in
                    FriendCandidateRow(profile: profile)
                }
            }

            ShareLink(
                item: URL(string: AppLinks.invite)!,
                subject: Text("Get early access to pickleball.ai"),
                message: Text("Get early access to pickleball.ai — log every match with your crew.")
            ) {
                Label("Share invite link", systemImage: "square.and.arrow.up")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
            }

            errorText

            primaryButton("Finish", systemImage: "checkmark.circle.fill") {
                Task { await finishOnboarding() }
            }

            Button {
                Task { await finishOnboarding() }
            } label: {
                Text("Skip for now")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
        }
    }

    /// App Store Review Guideline 1.2: users must affirmatively agree to the
    /// Terms of Use (which carry a zero-tolerance policy for objectionable
    /// content and abusive users) and the Privacy Policy before an account is
    /// created. This gate keeps "Send Code" disabled until the box is checked.
    /// The checkbox and the in-sentence links are separate tap targets so
    /// opening a document doesn't also toggle consent.
    private var termsGate: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                agreedToTerms.toggle()
            } label: {
                Image(systemName: agreedToTerms ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(agreedToTerms ? Theme.accent : Theme.textSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Agree to the Terms of Use and Privacy Policy")
            .accessibilityValue(agreedToTerms ? "Checked" : "Not checked")

            Text(consentText)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .tint(Theme.accent)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var consentText: AttributedString {
        let markdown = "I agree to the [Terms of Use](\(Legal.termsURL)) and [Privacy Policy](\(Legal.privacyURL)), and understand that pickleball.ai has **zero tolerance** for objectionable content or abusive behavior."
        return (try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)
    }

    @ViewBuilder
    private var errorText: some View {
        if let error = store.errorMessage {
            Text(error)
                .font(.footnote)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func primaryButton(
        _ title: String,
        systemImage: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                    .foregroundStyle(Theme.background)
                    .opacity(store.isBusy ? 0 : 1)
                if store.isBusy {
                    ProgressView().tint(Theme.background)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(store.isBusy || disabled)
        .opacity(disabled ? 0.5 : 1)
    }

    private func initialize() {
        guard !didInitialize else { return }
        didInitialize = true
        store.errorMessage = nil

        if startsAtProfile {
            prefillProfile()
            step = .profile
        } else if hasSeenOnboardingSplash {
            step = .phone
        }
    }

    private func prefillProfile() {
        guard let profile = store.currentProfile else { return }
        if profile.displayName != "Pickleball Player" {
            if let storedFirstName = profile.firstName, !storedFirstName.isEmpty,
               let storedLastName = profile.lastName, !storedLastName.isEmpty {
                firstName = storedFirstName
                lastName = storedLastName
            } else {
                let nameParts = Self.splitName(profile.displayName)
                firstName = nameParts.first
                lastName = nameParts.last
            }
        }
        if !profile.username.hasPrefix("player_") {
            username = profile.username
            didEditUsername = true
        } else if !fullName.isEmpty {
            username = ProfileIdentityValidator.suggestedUsername(firstName: firstName, lastName: lastName)
        }
        if let skill = profile.skillLevel, let level = SkillLevel(rawValue: skill) {
            selectedSkill = level
        }
        if let rating = profile.rating {
            duprRating = String(format: "%.2f", rating)
        }
    }

    private func finishOnboarding() async {
        let didComplete = await store.completeOnboarding(
            firstName: firstName,
            lastName: lastName,
            username: username,
            skillLevel: selectedSkill,
            duprRating: parsedDUPR
        )
        if didComplete {
            Haptics.success()
            contactStatus = nil
        }
    }

    private func syncContacts() async {
        contactStatus = "Checking contacts permission..."
        do {
            let granted = try await ContactsImporter.requestAccess()
            guard granted else {
                contactStatus = "Contacts access was not granted. Search or share an invite instead."
                return
            }
            let phones = try ContactsImporter.fetchPhones()
            guard !phones.isEmpty else {
                contactStatus = "No phone numbers found in contacts."
                return
            }
            contactStatus = "Looking for players in your contacts..."
            await store.matchContacts(phones: phones)
            if store.errorMessage != nil {
                contactStatus = nil
                return
            }
            contactStatus = store.contactMatches.isEmpty ? "No matching players found yet." : nil
        } catch {
            contactStatus = error.localizedDescription
        }
    }

    private var title: String {
        switch step {
        case .splash: return "Track every pickleball match with your crew."
        case .phone: return "Continue with your phone"
        case .code: return "Enter the code"
        case .profile: return "Claim your court name"
        case .skill: return "What is your level?"
        case .friends: return "Find your crew"
        }
    }

    private var subtitle: String {
        switch step {
        case .splash: return "Log sessions, compare streaks, and keep the group feed moving after every game."
        case .phone: return "We’ll sign you in or create your account."
        case .code: return ""
        case .profile: return ""
        case .skill: return "One tap gives the app a useful rating seed."
        case .friends: return "Sync contacts, search a username, or invite the crew yourself."
        }
    }

    private var normalizedPhone: String? {
        ContactsImporter.normalizePhone(phone)
    }

    private var codeDigits: String {
        code.filter(\.isNumber)
    }

    private var profileInitials: String {
        let letters = [firstName.trimmed.first, lastName.trimmed.first].compactMap { $0 }
        return letters.isEmpty ? "PB" : String(letters).uppercased()
    }

    private var profileIsValid: Bool {
        firstNameValidation.isValid
            && lastNameValidation.isValid
            && usernameValidation.isValid
            && (usernameAvailability == .available || usernameAvailability == .unavailable)
    }

    private var skillIsValid: Bool {
        selectedSkill != .dupr || parsedDUPR != nil
    }

    private var parsedDUPR: Double? {
        guard selectedSkill == .dupr else { return nil }
        guard let value = Double(duprRating), (2.0...8.0).contains(value) else { return nil }
        return value
    }

    private var fullName: String {
        [ProfileIdentityValidator.normalizedName(firstName), ProfileIdentityValidator.normalizedName(lastName)]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private var firstNameValidation: IdentityValidationResult {
        ProfileIdentityValidator.firstName(firstName)
    }

    private var lastNameValidation: IdentityValidationResult {
        let lastNameResult = ProfileIdentityValidator.lastName(lastName)
        guard lastNameResult.isValid else { return lastNameResult }
        return ProfileIdentityValidator.combinedName(firstName: firstName, lastName: lastName)
    }

    private var usernameValidation: IdentityValidationResult {
        ProfileIdentityValidator.username(username)
    }

    private var firstNameFeedback: IdentityFieldFeedback {
        nameFeedback(
            validation: firstNameValidation,
            field: .firstName
        )
    }

    private var lastNameFeedback: IdentityFieldFeedback {
        nameFeedback(
            validation: lastNameValidation,
            field: .lastName
        )
    }

    private var usernameFeedback: IdentityFieldFeedback {
        if touchedProfileFields.contains(.username), let error = usernameValidation.errorMessage {
            return .invalid(error)
        }
        guard usernameValidation.isValid else {
            return .none
        }
        switch usernameAvailability {
        case .idle, .available, .unavailable:
            return .none
        case .checking:
            return .checking
        case .taken:
            return .invalid("That username is already taken")
        }
    }

    private func nameFeedback(
        validation: IdentityValidationResult,
        field: ProfileField
    ) -> IdentityFieldFeedback {
        if touchedProfileFields.contains(field), let error = validation.errorMessage {
            return .invalid(error)
        }
        return .none
    }

    private func checkUsernameAvailability() async {
        usernameAvailability = .idle
        guard usernameValidation.isValid else { return }

        do {
            try await Task.sleep(for: .milliseconds(400))
        } catch {
            return
        }
        guard !Task.isCancelled else { return }

        usernameAvailability = .checking
        let isAvailable = await store.checkUsernameAvailability(username: username)
        guard !Task.isCancelled else { return }

        if let isAvailable {
            usernameAvailability = isAvailable ? .available : .taken
        } else {
            usernameAvailability = .unavailable
        }
    }

    private static func splitName(_ displayName: String) -> (first: String, last: String) {
        let parts = displayName.split(whereSeparator: \.isWhitespace)
        guard let first = parts.first else { return ("", "") }
        return (String(first), parts.dropFirst().joined(separator: " "))
    }
}

struct ConfigNeededView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 42))
                .foregroundStyle(Theme.accent)
            Text("Connect Supabase")
                .font(.title2.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
            Text("Copy PickleballAI/Supabase.example.plist to Supabase.plist and fill in your SUPABASE_URL and SUPABASE_ANON_KEY, then run supabase/schema.sql in the SQL editor.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
    }
}
