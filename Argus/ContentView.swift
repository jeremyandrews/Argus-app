import SwiftUI

struct ContentView: View {
    @State private var tabBarHeight: CGFloat = 0

    var body: some View {
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
            }
            .overlay(
                GeometryReader { geometry in
                    Color.clear.preference(key: TabBarHeightPreferenceKey.self, value: geometry.safeAreaInsets.bottom)
                }
            )
            .onPreferenceChange(TabBarHeightPreferenceKey.self) { value in
                tabBarHeight = value
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
