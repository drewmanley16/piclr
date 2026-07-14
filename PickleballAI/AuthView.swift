import SwiftUI

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

    let startsAtProfile: Bool

    @State private var step: Step
    @State private var didInitialize = false
    @State private var phone = ""
    @State private var verifiedPhone = ""
    @State private var code = ""
    @State private var displayName = ""
    @State private var username = ""
    @State private var didEditUsername = false
    @State private var selectedSkill = SkillLevel.intermediate
    @State private var duprRating = ""
    @State private var searchQuery = ""
    @State private var contactStatus: String?

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

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
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
                placeholder: "+1 555 000 0000",
                text: $phone,
                keyboard: .phonePad,
                autocapitalize: false,
                textContentType: .telephoneNumber
            )

            errorText

            primaryButton("Send Code", systemImage: "message.fill", disabled: normalizedPhone == nil) {
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

    private var codeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            AuthField(
                placeholder: "6-digit code",
                text: $code,
                keyboard: .numberPad,
                autocapitalize: false,
                textContentType: .oneTimeCode
            )

            HStack {
                Text(verifiedPhone)
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

            AuthField(
                placeholder: "Display name",
                text: $displayName,
                textContentType: .name
            )
            .onChange(of: displayName) { _, newValue in
                guard !didEditUsername else { return }
                username = Self.suggestUsername(from: newValue)
            }

            AuthField(
                placeholder: "Username",
                text: $username,
                autocapitalize: false,
                textContentType: .username
            )
            .onChange(of: username) { _, _ in
                didEditUsername = true
            }

            primaryButton("Continue", systemImage: "arrow.right", disabled: !profileIsValid) {
                username = username.normalizedUsername
                step = .skill
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
                item: URL(string: "https://pickleball.ai/invite")!,
                subject: Text("Join my pickleball crew"),
                message: Text("Add me on pickleball.ai and log matches with the crew.")
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
            displayName = profile.displayName
        }
        if !profile.username.hasPrefix("player_") {
            username = profile.username
            didEditUsername = true
        } else if !displayName.isEmpty {
            username = Self.suggestUsername(from: displayName)
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
            displayName: displayName,
            username: username,
            skillLevel: selectedSkill,
            duprRating: parsedDUPR
        )
        if didComplete {
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
        case .phone: return "Start with your phone"
        case .code: return "Enter the code"
        case .profile: return "Claim your court name"
        case .skill: return "What is your level?"
        case .friends: return "Find your crew"
        }
    }

    private var subtitle: String {
        switch step {
        case .splash: return "Log sessions, compare streaks, and keep the group feed moving after every game."
        case .phone: return "No passwords. We will text you a one-time code."
        case .code: return "Your phone can suggest the SMS code automatically."
        case .profile: return "A display name and username are enough to get rolling."
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
        let letters = displayName.split(separator: " ").prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "PB" : String(letters).uppercased()
    }

    private var profileIsValid: Bool {
        displayName.trimmed.count >= 2 && username.normalizedUsername.count >= 3
    }

    private var skillIsValid: Bool {
        selectedSkill != .dupr || parsedDUPR != nil
    }

    private var parsedDUPR: Double? {
        guard selectedSkill == .dupr else { return nil }
        guard let value = Double(duprRating), (2.0...8.0).contains(value) else { return nil }
        return value
    }

    private static func suggestUsername(from name: String) -> String {
        let suggestion = name.normalizedUsername
        return suggestion.isEmpty ? "" : suggestion
    }
}

struct OnboardingPreviewCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                ProfileAvatar(url: nil, initials: "DM", size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Drew & Maya won")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text("11-8 at Riverside Courts")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Text("now")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }

            HStack(spacing: 8) {
                FocusChip(title: "Third Shot")
                FocusChip(title: "4 wins")
                FocusChip(title: "Crew")
            }

            Divider().overlay(Theme.hairline)

            VStack(alignment: .leading, spacing: 10) {
                LeaderboardPreviewRow(rank: 1, name: "Maya", record: "18-7")
                LeaderboardPreviewRow(rank: 2, name: "Sam", record: "16-9")
                LeaderboardPreviewRow(rank: 3, name: "Drew", record: "13-11")
            }
        }
        .cardStyle()
    }
}

struct LeaderboardPreviewRow: View {
    var rank: Int
    var name: String
    var record: String

    var body: some View {
        HStack {
            Text("\(rank)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 28, alignment: .leading)
            Text(name)
                .font(.body.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Text(record)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

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

struct FriendCandidateRow: View {
    @EnvironmentObject private var store: AppStore
    var profile: Profile
    /// When true, tapping the name/avatar area pushes the player's profile
    /// (Instagram-style). Only enable within a NavigationStack.
    var navigable: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            if navigable {
                NavigationLink {
                    OtherProfileView(userId: profile.id, placeholder: profile)
                } label: {
                    identity
                }
                .buttonStyle(.plain)
            } else {
                identity
            }
            followButton
        }
        .cardStyle()
    }

    private var identity: some View {
        HStack(spacing: 12) {
            ProfileAvatar(profile: profile, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(profile.displayName)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("@\(profile.username)")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }

    private var followButton: some View {
        Button {
            Task { await store.sendFollowRequest(to: profile) }
        } label: {
            Image(systemName: store.requestedFollowIds.contains(profile.id) ? "checkmark" : "plus")
                .font(.body.weight(.bold))
                .foregroundStyle(store.requestedFollowIds.contains(profile.id) ? Theme.textTertiary : Theme.background)
                .frame(width: 40, height: 40)
                .background(store.requestedFollowIds.contains(profile.id) ? Theme.surfaceElevated : Theme.accent, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(store.requestedFollowIds.contains(profile.id) || store.isBusy)
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
