import SwiftUI

struct ContentView: View {
    @State private var tabBarHeight: CGFloat = 0
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        if horizontalSizeClass == .regular {
            // iPad Layout
            NavigationSplitView {
                List {
                    NavigationLink(destination: NewsView(tabBarHeight: $tabBarHeight)) {
                        Label("News", systemImage: "newspaper")
                    }
                    NavigationLink(destination: SubscriptionsView()) {
                        Label("Subscriptions", systemImage: "mail")
                    }
                    NavigationLink(destination: SettingsView()) {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
                .navigationTitle("Argus")
            } detail: {
                NewsView(tabBarHeight: $tabBarHeight)
            }
        } else {
            // iPhone Layout (existing TabView)
            ZStack(alignment: .bottom) {
                TabView {
                    NewsView(tabBarHeight: $tabBarHeight)
                        .tabItem {
                            Image(systemName: "newspaper")
                            Text("News")
                        }
                    SubscriptionsView()
                        .tabItem {
                            Image(systemName: "mail")
                            Text("Subscriptions")
                        }
                    SettingsView()
                        .tabItem {
                            Image(systemName: "gearshape")
                            Text("Settings")
                        }
                }
                .overlay(
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: TabBarHeightPreferenceKey.self,
                            value: geometry.safeAreaInsets.bottom
                        )
                    }
                )
                .onPreferenceChange(TabBarHeightPreferenceKey.self) { value in
                    tabBarHeight = value
                }
            }
        }
    }
}

struct TabBarHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
