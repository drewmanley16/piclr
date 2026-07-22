import SwiftUI
import UIKit

struct RootView: View {
    init() {
        // Match navigation bars to the black canvas.
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = UIColor(Theme.background)
        nav.shadowColor = .clear
        nav.titleTextAttributes = [.foregroundColor: UIColor.white]
        nav.largeTitleTextAttributes = [.foregroundColor: UIColor.white]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
    }

    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @State private var selectedTab = 0
    /// One counter per tab; re-tapping the active tab bumps its counter, which
    /// the tab's `ProfileNavigationStack` observes to pop back to root.
    @State private var reselectTokens = [0, 0, 0]

    var body: some View {
        Group {
            switch store.authState {
            case .loading:
                ProgressView()
                    .tint(Theme.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.background.ignoresSafeArea())
            case .unconfigured:
                ConfigNeededView()
            case .signedOut:
                AuthView()
            case .needsOnboarding:
                AuthView(startsAtProfile: true)
            case .signedIn:
                mainTabs
            }
        }
        .task {
            if store.authState == .loading {
                await store.start()
            }
        }
        // Personalized invite links. Universal links (an installed app opening
        // https://…/u/{id}) arrive as a browsing user activity; a custom-scheme
        // fallback would arrive via onOpenURL. Both route into the deep-link
        // system, which presents the profile once signed in.
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL { store.handleInviteURL(url) }
        }
        .onOpenURL { store.handleInviteURL($0) }
        .sheet(item: $subscriptions.paywallContext) { context in
            PaywallView(context: context)
        }
    }

    private var mainTabs: some View {
        // Paging TabView drives the swipe; the native tab bar is hidden and
        // replaced by AppTabBar so both tap and swipe move between pages.
        TabView(selection: $selectedTab) {
            HomeView(reselectSignal: reselectTokens[0]).tag(0)
            WorkoutView(reselectSignal: reselectTokens[1]).tag(1)
            ProfileView(reselectSignal: reselectTokens[2]).tag(2)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(Theme.background.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AppTabBar(selection: $selectedTab) { index in
                reselectTokens[index] += 1
                Haptics.tap()
            }
        }
        .onChange(of: selectedTab) { _, _ in Haptics.tap() }
        .sheet(item: Binding(
            get: { store.pendingDeepLink },
            set: { store.pendingDeepLink = $0 }
        )) { link in
            NavigationStack {
                Group {
                    switch link {
                    case .session(let id):
                        SessionDetailView(sessionId: id)
                    case .comments(let id):
                        SessionDetailView(sessionId: id, openComments: true)
                    case .profile(let id):
                        OtherProfileView(userId: id, placeholder: nil)
                    case .invite(let id):
                        InviteDetailView(inviteId: id)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { store.pendingDeepLink = nil }
                    }
                }
            }
        }
    }
}

/// Custom bottom tab bar replacing the native `UITabBar`, so the app pages can
/// live in a paging `TabView` (swipeable) while still tapping between Home /
/// Play / Profile. Styled with `Theme` to match the all-black canvas.
private struct AppTabBar: View {
    @Binding var selection: Int
    /// Called when the already-active tab is tapped again (native "tap active
    /// tab" behavior). Switching to a different tab goes through `selection`.
    var onReselect: (Int) -> Void = { _ in }

    private let items: [(title: String, icon: String)] = [
        ("Home", "house.fill"),
        ("Play", "figure.pickleball"),
        ("Profile", "person.fill")
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { index in
                let selected = selection == index
                Button {
                    if selected {
                        onReselect(index)
                    } else {
                        withAnimation(.easeInOut(duration: 0.25)) { selection = index }
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: items[index].icon)
                            .font(.system(size: 22, weight: .regular))
                        Text(items[index].title)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(selected ? Theme.accent : Theme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(items[index].title)
                .accessibilityValue("Tab \(index + 1) of \(items.count)")
                .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(.top, 10)
        // Home-button iPhones / iPad have no bottom safe-area inset, so give the
        // labels breathing room from the screen edge rather than sitting flush.
        .padding(.bottom, 6)
        .accessibilityElement(children: .contain)
        .background(
            Theme.background
                .overlay(Theme.hairline.frame(height: 0.5), alignment: .top)
                .ignoresSafeArea(edges: .bottom)
        )
    }
}
