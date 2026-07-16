import SwiftUI

@main
struct PickleballAIApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = AppStore()
    @StateObject private var subscriptions = SubscriptionStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(subscriptions)
                .tint(Theme.accent)
                .preferredColorScheme(.dark)
        }
    }
}

