import SwiftUI

struct AuthView: View {
    @EnvironmentObject private var store: AppStore

    enum Mode { case signIn, signUp }

    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var username = ""
    @State private var displayName = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 10) {
                    Image(systemName: "figure.pickleball")
                        .font(.system(size: 46, weight: .bold))
                        .foregroundStyle(Theme.accent)
                    Text("pickleball.ai")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(mode == .signIn ? "Welcome back" : "Create your account")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.top, 72)
                .padding(.bottom, 8)

                VStack(spacing: 12) {
                    if mode == .signUp {
                        AuthField(placeholder: "Display name", text: $displayName)
                        AuthField(placeholder: "Username", text: $username, autocapitalize: false)
                    }
                    AuthField(placeholder: "Email", text: $email, keyboard: .emailAddress, autocapitalize: false)
                    AuthField(placeholder: "Password", text: $password, secure: true)
                }

                if let error = store.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    Task {
                        store.errorMessage = nil
                        switch mode {
                        case .signIn:
                            await store.signIn(email: email, password: password)
                        case .signUp:
                            await store.signUp(
                                email: email,
                                password: password,
                                username: username,
                                displayName: displayName
                            )
                        }
                    }
                } label: {
                    ZStack {
                        Text(mode == .signIn ? "Sign In" : "Sign Up")
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
                .disabled(store.isBusy || !isValid)
                .opacity(isValid ? 1 : 0.5)

                Button {
                    withAnimation {
                        mode = (mode == .signIn) ? .signUp : .signIn
                        store.errorMessage = nil
                    }
                } label: {
                    Text(mode == .signIn ? "New here? Create an account" : "Have an account? Sign in")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 20)
        }
        .background(Theme.background.ignoresSafeArea())
    }

    private var isValid: Bool {
        let base = email.contains("@") && password.count >= 6
        if mode == .signUp {
            return base && !username.isEmpty && !displayName.isEmpty
        }
        return base
    }
}

struct AuthField: View {
    var placeholder: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default
    var autocapitalize: Bool = true
    var secure: Bool = false

    var body: some View {
        Group {
            if secure {
                SecureField("", text: $text, prompt: prompt)
            } else {
                TextField("", text: $text, prompt: prompt)
                    .keyboardType(keyboard)
                    .textInputAutocapitalization(autocapitalize ? .words : .never)
                    .autocorrectionDisabled(!autocapitalize)
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
