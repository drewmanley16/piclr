import SwiftUI
import UIKit

struct RootView: View {
    init() {
        // True-black tab bar with a hairline top edge.
        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = UIColor(Theme.background)
        tab.shadowColor = UIColor(Theme.hairline)
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab

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
        .sheet(item: $subscriptions.paywallContext) { context in
            PaywallView(context: context)
        }
    }

    private var mainTabs: some View {
        TabView(selection: $selectedTab) {
            HomeView()
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }
                .tag(0)

            WorkoutView()
                .tabItem {
                    Label("Play", systemImage: "figure.pickleball")
                }
                .tag(1)

            ProfileView()
                .tabItem {
                    Label("Profile", systemImage: "person.fill")
                }
                .tag(2)
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
