import SwiftUI

// MARK: - Settings: Legal

/// One of the app's legal documents. Rendered in-app from bundled text so the
/// documents are readable without a live website (App Store reviewers use the
/// pre-onboarded demo account and never pass through the sign-up consent gate,
/// so this is where they can verify our Terms/Privacy and the UGC policy).
enum LegalDoc: String, Identifiable {
    case terms
    case privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .terms: return "Terms of Use"
        case .privacy: return "Privacy Policy"
        }
    }

    var body: String {
        switch self {
        case .terms: return LegalText.terms
        case .privacy: return LegalText.privacy
        }
    }

    var url: String {
        switch self {
        case .terms: return Legal.termsURL
        case .privacy: return Legal.privacyURL
        }
    }
}

struct SettingsLegalView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                LegalDocRow(doc: .terms)
                LegalDocRow(doc: .privacy)
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Legal")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LegalDocRow: View {
    let doc: LegalDoc

    var body: some View {
        NavigationLink {
            LegalDocumentView(doc: doc)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "doc.text")
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 40, height: 40)
                    .background(Theme.accentSoft, in: Circle())

                Text(doc.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .cardStyle()
    }
}

/// Renders a legal document's markdown. Uses `.inlineOnlyPreservingWhitespace`
/// so paragraph breaks are kept and inline styling (bold, links) is applied.
struct LegalDocumentView: View {
    let doc: LegalDoc

    var body: some View {
        ScrollView {
            Text(rendered)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
                .tint(Theme.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(doc.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var rendered: AttributedString {
        (try? AttributedString(
            markdown: doc.body,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(doc.body)
    }
}

/// Draft legal copy shown in-app. NOTE: this is a starting point, not
/// legal advice — have counsel review before launch, and keep it in sync with
/// the hosted copies at `Legal.termsURL` / `Legal.privacyURL`.
enum LegalText {
    static let terms = """
    **Effective date: July 15, 2026**

    Welcome to piclr ("the App"). These Terms of Use ("Terms") are a legal agreement between you and piclr ("we", "us"). By creating an account or using the App, you agree to these Terms. If you do not agree, do not use the App.

    **1. Eligibility**
    You must be at least 13 years old to use the App. If you are under the age of majority where you live, you may only use the App with the involvement of a parent or guardian.

    **2. Your account**
    You sign in with your phone number and a one-time code. You are responsible for activity on your account and for keeping access to your phone number secure.

    **3. Content you post**
    You keep ownership of the sessions, comments, photos, and other content you post ("Your Content"). You grant us a non-exclusive, worldwide, royalty-free license to host, store, and display Your Content solely to operate and improve the App. You are responsible for Your Content and confirm you have the rights to share it.

    **4. Community rules: zero tolerance for objectionable content and abusive users**
    We have zero tolerance for objectionable content or abusive behavior. You agree not to post content or engage in conduct that is unlawful, harassing, bullying, threatening, hateful, defamatory, sexually explicit, violent, or that impersonates others, invades privacy, promotes cheating, or is spam. This is not an exhaustive list.

    We reserve the right, but are not obligated, to review content. When we receive a report of objectionable content or abusive behavior, we act on it, including removing the content and ejecting the user who provided it, generally within 24 hours. You can report content or users from within the App (tap the "•••" menu on a profile, post, or comment) and block users at any time.

    **5. Subscriptions (piclr Pro)**
    piclr Pro is an auto-renewing subscription offered in monthly and annual terms, billed through your Apple ID at the price shown on the purchase screen at the time you subscribe. Payment is charged to your Apple ID account at confirmation of purchase. Your subscription automatically renews for the same term unless you turn off auto-renew at least 24 hours before the end of the current period; your account will be charged for renewal within 24 hours prior to the end of the current period. You can manage or cancel your subscription any time in iOS Settings → [your name] → Subscriptions, or from Settings → Manage Subscription in the App. Any unused portion of a free trial period, if offered, is forfeited when you purchase a subscription. Refunds are handled by Apple in accordance with the App Store's refund policies, not by us.

    **6. Termination**
    We may suspend or terminate your access to the App at any time if you violate these Terms. You may stop using the App at any time and can permanently delete your account from Settings → Account.

    **7. Disclaimers**
    The App is provided "as is" and "as available," without warranties of any kind. We do not guarantee that the App will be uninterrupted, secure, or error-free.

    **8. Limitation of liability**
    To the fullest extent permitted by law, we will not be liable for any indirect, incidental, special, consequential, or punitive damages, or any loss of data, arising from your use of the App.

    **9. Changes to these Terms**
    We may update these Terms from time to time. If we make material changes, we will notify you within the App or by other reasonable means. Continued use after changes take effect means you accept the updated Terms.

    **10. Apple App Store**
    These Terms are between you and us, not Apple. Apple is not responsible for the App or its content. Apple and its subsidiaries are third-party beneficiaries of these Terms and may enforce them against you. Apple has no obligation to provide support or maintenance for the App.

    **11. Contact**
    Questions about these Terms? Contact us at drewmanley16@gmail.com.
    """

    static let privacy = """
    **Effective date: July 15, 2026**

    This Privacy Policy explains what piclr ("we", "us") collects and how we use it. By using the App you agree to this policy.

    **1. Information we collect**
    • Phone number: used to create and sign in to your account (via SMS one-time code).
    • Profile information: display name, username, skill/rating, home court, and any photo you choose to add.
    • Content: sessions, comments, likes, and other content you create.
    • Contacts: if you choose to find friends, we match your contacts' phone numbers once to look for existing users. Contacts are matched in the moment and are not stored.
    • Device tokens: if you enable notifications, we store a push token to deliver them.
    • Apple Watch scores: if you score a game on the paired Apple Watch, the running score is relayed to the iPhone app and saved with the session you post. The App does not read or write Apple Health data.
    • Subscription status: if you subscribe to Pro, our payment provider (RevenueCat, on top of Apple's in-app purchase system) shares your subscription status and renewal dates with us. We never see or store your payment card details — Apple handles those directly.
    • Analytics/usage data: we use PostHog to understand how the App is used (e.g. which features are opened, how often you post). This is tied to an internal user identifier and a few profile attributes (skill level, whether you have a DUPR rating, Pro status) so we can improve the App. It is not shared with advertisers and is not used to track you across other companies' apps or websites.
    • Basic diagnostic data needed to operate the service.

    **2. How we use information**
    We use your information to operate the App: to authenticate you, show your feed and profile, record sessions, deliver notifications, enable social features (follows, comments, contact matching), manage your subscription, understand feature usage, and to keep the community safe (handling reports, blocks, and abuse). Fitness data is never used for advertising or analytics.

    **3. How information is shared**
    We share information with service providers who help us run the App, including our backend host (Supabase), our SMS provider (Twilio, to send your login code), Apple Push Notification service (to deliver notifications), RevenueCat (to manage subscriptions), and PostHog (analytics). We do not sell your personal information. We may disclose information if required by law.

    **4. Data retention and deletion**
    We keep your information for as long as your account is active. You can permanently delete your account and associated content at any time from Settings → Account → Delete Account.

    **5. Your choices**
    You control your profile information and whether to grant Contacts and Notifications permissions, which you can change at any time in system Settings. You can block or report other users at any time.

    **6. Children**
    The App is not intended for children under 13, and we do not knowingly collect information from them.

    **7. Changes to this policy**
    We may update this policy from time to time and will notify you of material changes within the App or by other reasonable means.

    **8. Contact**
    Questions about privacy? Contact us at drewmanley16@gmail.com.
    """
}
