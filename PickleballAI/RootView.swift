import SwiftUI

struct RootView: View {
    @State private var isShowingQuickLog = false

    var body: some View {
        TabView {
            FeedView(isShowingQuickLog: $isShowingQuickLog)
                .tabItem {
                    Label("Feed", systemImage: "list.bullet.rectangle")
                }

            LogView()
                .tabItem {
                    Label("Log", systemImage: "plus.circle")
                }

            GroupsView()
                .tabItem {
                    Label("Groups", systemImage: "person.3")
                }

            ProfileView()
                .tabItem {
                    Label("Profile", systemImage: "person.crop.circle")
                }
        }
        .sheet(isPresented: $isShowingQuickLog) {
            NavigationStack {
                LogView(isPresentedAsSheet: true)
            }
            .presentationDetents([.large])
        }
    }
}

