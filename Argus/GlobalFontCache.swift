import SwiftUI
import Combine
import Foundation

/// Global font cache that observes UserDefaults changes and provides cached font computations
/// This eliminates the 10-50ms font computation overhead on every NewsDetailView appearance
/// Uses Swift 6 and iOS 18+ patterns with proper @MainActor isolation
@MainActor
final class GlobalFontCache: ObservableObject {
    
    // MARK: - Singleton
    
    static let shared = GlobalFontCache()
    
    // MARK: - Published Properties
    
    /// Cached font for article titles and body text
    @Published private(set) var cachedFont: Font?
    
    /// Cached font for article descriptions and summaries
    @Published private(set) var cachedDescriptionFont: Font?
    
    /// Cached font color based on current settings
    @Published private(set) var cachedFontColor: Color?
    
    /// Cached text display settings for comparison
    @Published private(set) var cachedSettings: TextDisplaySettings?
    
    // MARK: - Private Properties
    
    /// Subscriptions for UserDefaults changes
    private var cancellables = Set<AnyCancellable>()
    
    /// Last computed settings hash to avoid unnecessary recomputation
    private var lastSettingsHash: Int = 0
    
    // MARK: - Initialization
    
    private init() {
        // Initial cache computation
        updateCache()
        
        // Observe UserDefaults changes for text display settings
        observeSettingsChanges()
        
        AppLogger.database.debug("🎨 GlobalFontCache: Initialized with cached fonts")
    }
    
    deinit {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }
    
    // MARK: - Public Methods
    
    /// Forces a cache update - useful for testing or manual refresh
    func refreshCache() {
        updateCache()
    }
    
    /// Gets the current text display settings hash for comparison
    func getCurrentSettingsHash() -> Int {
        let settings = UserDefaults.standard.textDisplaySettings
        var hasher = Hasher()
        hasher.combine(settings.fontSize.rawValue)
        hasher.combine(settings.fontWeight.rawValue)
        hasher.combine(settings.fontColor.rawValue)
        hasher.combine(settings.fontFamily.rawValue)
        hasher.combine(settings.backgroundColor.rawValue)
        return hasher.finalize()
    }
    
    // MARK: - Private Methods
    
    /// Updates all cached font properties based on current UserDefaults
    private func updateCache() {
        let startTime = Date()
        
        let settings = UserDefaults.standard.textDisplaySettings
        let currentHash = getCurrentSettingsHash()
        
        // Skip update if settings haven't changed
        if currentHash == lastSettingsHash {
            AppLogger.database.debug("🎨 GlobalFontCache: Settings unchanged, skipping cache update")
            return
        }
        
        // Update cached fonts and settings
        cachedFont = settings.font
        cachedDescriptionFont = settings.descriptionFont
        cachedFontColor = settings.fontColor.color
        cachedSettings = settings
        
        // Update hash
        lastSettingsHash = currentHash
        
        let updateTime = Date().timeIntervalSince(startTime)
        AppLogger.database.debug("🎨 GlobalFontCache: Updated cache in \(String(format: "%.3f", updateTime * 1000))ms")
        AppLogger.database.debug("   - Font: \(settings.fontSize.rawValue), \(settings.fontWeight.rawValue)")
        AppLogger.database.debug("   - Color: \(settings.fontColor.rawValue)")
        AppLogger.database.debug("   - Family: \(settings.fontFamily.rawValue)")
    }
    
    /// Sets up observers for UserDefaults changes
    private func observeSettingsChanges() {
        let defaults = UserDefaults.standard
        
        // Observe text display settings changes
        defaults.publisher(for: \.textDisplaySettings)
            .removeDuplicates { first, second in
                // Compare settings by converting to hash
                var firstHasher = Hasher()
                firstHasher.combine(first.fontSize.rawValue)
                firstHasher.combine(first.fontWeight.rawValue)
                firstHasher.combine(first.fontColor.rawValue)
                firstHasher.combine(first.fontFamily.rawValue)
                firstHasher.combine(first.backgroundColor.rawValue)
                
                var secondHasher = Hasher()
                secondHasher.combine(second.fontSize.rawValue)
                secondHasher.combine(second.fontWeight.rawValue)
                secondHasher.combine(second.fontColor.rawValue)
                secondHasher.combine(second.fontFamily.rawValue)
                secondHasher.combine(second.backgroundColor.rawValue)
                
                return firstHasher.finalize() == secondHasher.finalize()
            }
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.updateCache()
                }
            }
            .store(in: &cancellables)
        
        AppLogger.database.debug("🎨 GlobalFontCache: Set up UserDefaults observers")
    }
}

// MARK: - Convenience Extensions

extension GlobalFontCache {
    
    /// Returns cached font or computes it if cache is empty
    var font: Font {
        return cachedFont ?? UserDefaults.standard.textDisplaySettings.font
    }
    
    /// Returns cached description font or computes it if cache is empty
    var descriptionFont: Font {
        return cachedDescriptionFont ?? UserDefaults.standard.textDisplaySettings.descriptionFont
    }
    
    /// Returns cached font color or computes it if cache is empty
    var fontColor: Color {
        return cachedFontColor ?? UserDefaults.standard.textDisplaySettings.fontColor.color
    }
    
    /// Returns cached settings or current settings if cache is empty
    var settings: TextDisplaySettings {
        return cachedSettings ?? UserDefaults.standard.textDisplaySettings
    }
}
