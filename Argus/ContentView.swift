import SwiftUI

struct ContentView: View {
    @State private var tabBarHeight: CGFloat = 0
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showSwiftDataTest = false
    @State private var selectedTab = 0
    @State private var tabNavigation = TabNavigationState()

    var body: some View {
        if horizontalSizeClass == .regular {
            // iPad Layout
            NavigationSplitView {
                List {
                    NavigationLink(destination: NewsView(tabBarHeight: $tabBarHeight)
                        .environment(tabNavigation)) {
                        Label("News", systemImage: "newspaper")
                    }
                    NavigationLink(destination: SubscriptionsView()
                        .environment(tabNavigation)) {
                        Label("Subscriptions", systemImage: "mail")
                    }
                    NavigationLink(destination: SettingsView()
                        .environment(tabNavigation)) {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
                .navigationTitle("Argus")
            } detail: {
                NewsView(tabBarHeight: $tabBarHeight)
                    .environment(tabNavigation)
            }
            .onAppear {
                // Phase 2.1: App Launch Sync - Schedule initial sync after app launch
                Task {
                    await AutoSyncCoordinator.shared.scheduleInitialSync()
                }
            }
        } else {
            // iPhone Layout (existing TabView)
            ZStack(alignment: .bottom) {
                TabView(selection: $selectedTab) {
                    NewsView(tabBarHeight: $tabBarHeight)
                        .environment(tabNavigation)
                        .tabItem {
                            Image(systemName: "newspaper")
                            Text("News")
                        }
                        .tag(0)
                    SubscriptionsView()
                        .environment(tabNavigation)
                        .tabItem {
                            Image(systemName: "mail")
                            Text("Subscriptions")
                        }
                        .tag(1)
                    SettingsView()
                        .environment(tabNavigation)
                        .tabItem {
                            Image(systemName: "gearshape")
                            Text("Settings")
                        }
                        .tag(2)
                }
                .background(
                    TabBarAccessor { newTab in
                        print("ContentView: TabBarAccessor callback - selectedTab: \(selectedTab), newTab: \(newTab)")
                        
                        // Always call handleTabSelectionChange - let it decide what to do
                        handleTabSelectionChange(from: selectedTab, to: newTab)
                        
                        // Update selectedTab to match the actual selection
                        if selectedTab != newTab {
                            selectedTab = newTab
                        }
                    }
                )
                .onChange(of: selectedTab) { oldTab, newTab in
                    print("ContentView: onChange fired - \(oldTab) -> \(newTab)")
                    // This onChange will fire when we programmatically update selectedTab above
                    // Don't double-process here since TabBarAccessor already handled it
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
                .onAppear {
                    // Phase 2.1: App Launch Sync - Schedule initial sync after app launch
                    Task {
                        await AutoSyncCoordinator.shared.scheduleInitialSync()
                    }
                }
            }
        }
    }
    
    @MainActor
    private func handleTabSelectionChange(from oldTab: Int, to newTab: Int) {
        print("ContentView: handleTabSelectionChange - from: \(oldTab) to: \(newTab)")
        let action = tabNavigation.handleTabSelection(newTab, currentlySelected: oldTab)
        print("ContentView: action returned: \(action)")
        handleTabAction(action, for: newTab)
    }
    
    @MainActor
    private func handleTabAction(_ action: TabAction, for tab: Int) {
        print("ContentView: handleTabAction - action: \(action), tab: \(tab)")
        switch action {
        case .navigateToTab:
            print("ContentView: navigateToTab action")
            break
        case .scrollToTop:
            print("ContentView: scrollToTop action, posting notification")
            NotificationCenter.default.post(
                name: .tabScrollToTop, 
                object: tab,
                userInfo: ["tabIndex": tab]
            )
            // Mark that scroll-to-top has been triggered for this tab
            tabNavigation.markScrolledToTop(for: tab)
        case .navigateUp:
            print("ContentView: navigateUp action, checking if in subview...")
            if tabNavigation.isInSubview(for: tab) {
                print("ContentView: In subview, posting navigateUp notification")
                NotificationCenter.default.post(
                    name: .tabNavigateUp, 
                    object: tab
                )
            } else {
                print("ContentView: Not in subview, ignoring navigateUp")
            }
        case .none:
            print("ContentView: none action")
            break
        }
    }
}

struct TabBarHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// UIKit integration to detect same-tab taps
struct TabBarAccessor: UIViewControllerRepresentable {
    var callback: (Int) -> Void
    
    func makeUIViewController(context: Context) -> TabBarAccessorViewController {
        let vc = TabBarAccessorViewController()
        vc.callback = callback
        return vc
    }
    
    func updateUIViewController(_ uiViewController: TabBarAccessorViewController, context: Context) {
        uiViewController.callback = callback
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator: NSObject {
        // Empty coordinator for now
    }
}

class TabBarAccessorViewController: UIViewController, UITabBarControllerDelegate {
    var callback: ((Int) -> Void)?
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        // Find the tab bar controller and set ourselves as delegate
        DispatchQueue.main.async {
            self.findAndSetupTabBarController()
        }
    }
    
    private func findAndSetupTabBarController() {
        // Search up the view controller hierarchy for UITabBarController
        var currentVC: UIViewController? = self
        while currentVC != nil {
            if let tabBarController = currentVC as? UITabBarController {
                print("TabBarAccessor: Found UITabBarController, setting delegate")
                tabBarController.delegate = self
                return
            }
            currentVC = currentVC?.parent
        }
        
        // If not found in parents, search in the view hierarchy
        if let window = view.window {
            if let tabBarController = findTabBarController(in: window.rootViewController) {
                print("TabBarAccessor: Found UITabBarController in window hierarchy, setting delegate")
                tabBarController.delegate = self
                return
            }
        }
        
        print("TabBarAccessor: Could not find UITabBarController")
    }
    
    private func findTabBarController(in viewController: UIViewController?) -> UITabBarController? {
        guard let vc = viewController else { return nil }
        
        if let tabBarController = vc as? UITabBarController {
            return tabBarController
        }
        
        for child in vc.children {
            if let found = findTabBarController(in: child) {
                return found
            }
        }
        
        return nil
    }
    
    // MARK: - UITabBarControllerDelegate
    
    func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
        let newIndex = tabBarController.viewControllers?.firstIndex(of: viewController) ?? 0
        let currentIndex = tabBarController.selectedIndex
        
        print("TabBarAccessor: shouldSelect called - current: \(currentIndex), new: \(newIndex)")
        
        // Always call the callback - ContentView will handle the logic
        callback?(newIndex)
        
        return true
    }
}
