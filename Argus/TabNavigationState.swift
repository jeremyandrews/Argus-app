import SwiftUI
import Foundation

@Observable
final class TabNavigationState {
    private var tabNavigationStacks: [Int: NavigationState] = [:]
    private var tabScrollPositions: [Int: ScrollPosition] = [:]
    
    struct NavigationState {
        var isInSubview: Bool = false
        var currentLevel: Int = 0
    }
    
    struct ScrollPosition {
        var isAtTop: Bool = true
        var lastScrollOffset: CGFloat = 0
        var hasScrolledToTopOnce: Bool = false
    }
    
    @MainActor
    func handleTabSelection(_ tabIndex: Int, currentlySelected: Int) -> TabAction {
        print("TabNavigationState: Tab \(tabIndex) clicked, currentlySelected: \(currentlySelected)")
        
        if tabIndex != currentlySelected {
            // Different tab: Navigate to tab
            print("TabNavigationState: Different tab, navigating")
            return .navigateToTab
        }
        
        // Same tab clicked - progressive navigation based on current state
        let scrollPosition = tabScrollPositions[tabIndex] ?? ScrollPosition()
        let isInSubview = isInSubview(for: tabIndex)
        
        print("TabNavigationState: Same tab clicked - isAtTop: \(scrollPosition.isAtTop), inSubview: \(isInSubview), hasScrolledToTopOnce: \(scrollPosition.hasScrolledToTopOnce)")
        
        if !scrollPosition.isAtTop {
            // Not at top: Scroll to top (first priority)
            print("TabNavigationState: Not at top, scrolling to top")
            return .scrollToTop
        } else if !isInSubview {
            // At top but not in subview: Scroll to top (ensure we're really at top)
            print("TabNavigationState: At top but not in subview, scrolling to top")
            return .scrollToTop
        } else if !scrollPosition.hasScrolledToTopOnce {
            // In subview, at top, but haven't explicitly scrolled to top yet
            print("TabNavigationState: In subview but haven't scrolled to top yet, scrolling to top first")
            return .scrollToTop
        } else {
            // At top AND in subview AND have already scrolled to top: Navigate up
            print("TabNavigationState: At top, in subview, and already scrolled to top, navigating up")
            return .navigateUp
        }
    }
    
    @MainActor
    func setNavigationState(for tabIndex: Int, inSubview: Bool, level: Int = 1) {
        print("TabNavigationState: setNavigationState - tab: \(tabIndex), inSubview: \(inSubview), level: \(level)")
        tabNavigationStacks[tabIndex] = NavigationState(isInSubview: inSubview, currentLevel: level)
        
        // Reset hasScrolledToTopOnce when returning to parent view
        if !inSubview && level == 0 {
            print("TabNavigationState: Returning to parent view, resetting hasScrolledToTopOnce for tab \(tabIndex)")
            var currentPosition = tabScrollPositions[tabIndex] ?? ScrollPosition()
            currentPosition.hasScrolledToTopOnce = false
            tabScrollPositions[tabIndex] = currentPosition
        }
    }
    
    @MainActor
    func isInSubview(for tabIndex: Int) -> Bool {
        let result = tabNavigationStacks[tabIndex]?.isInSubview ?? false
        print("TabNavigationState: isInSubview for tab \(tabIndex): \(result)")
        return result
    }
    
    @MainActor
    func updateScrollPosition(for tabIndex: Int, isAtTop: Bool, scrollOffset: CGFloat = 0) {
        print("TabNavigationState: updateScrollPosition - tab: \(tabIndex), isAtTop: \(isAtTop), offset: \(scrollOffset)")
        let currentPosition = tabScrollPositions[tabIndex] ?? ScrollPosition()
        tabScrollPositions[tabIndex] = ScrollPosition(
            isAtTop: isAtTop, 
            lastScrollOffset: scrollOffset,
            hasScrolledToTopOnce: currentPosition.hasScrolledToTopOnce
        )
    }
    
    @MainActor
    func markScrolledToTop(for tabIndex: Int) {
        print("TabNavigationState: markScrolledToTop - tab: \(tabIndex)")
        var currentPosition = tabScrollPositions[tabIndex] ?? ScrollPosition()
        currentPosition.hasScrolledToTopOnce = true
        currentPosition.isAtTop = true
        tabScrollPositions[tabIndex] = currentPosition
    }
    
    @MainActor
    func resetScrollState(for tabIndex: Int) {
        print("TabNavigationState: resetScrollState - tab: \(tabIndex)")
        tabScrollPositions[tabIndex] = ScrollPosition()
    }
    
    @MainActor
    func getScrollPosition(for tabIndex: Int) -> ScrollPosition {
        return tabScrollPositions[tabIndex] ?? ScrollPosition()
    }
}

enum TabAction {
    case navigateToTab
    case scrollToTop  
    case navigateUp
    case none
}

// MARK: - Notification Extensions

extension Notification.Name {
    static let tabScrollToTop = Notification.Name("tab.scrollToTop")
    static let tabNavigateUp = Notification.Name("tab.navigateUp")
}
