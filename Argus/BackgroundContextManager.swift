// Argus/BackgroundContextManager.swift
import Foundation
import SwiftData

// BackgroundContextManager provides thread-safe access to background contexts.
// This centralizes the creation of background ModelContexts, ensuring we don't
// accidentally perform database operations on the main thread.
class BackgroundContextManager {
    static let shared = BackgroundContextManager()

    func performBackgroundTask<T>(_ task: @escaping (ModelContext) -> T) async -> T {
        return await Task.detached {
            // Create a fresh ModelContext from your main container each time
            let context = await ModelContext(ArgusApp.sharedModelContainer)
            return task(context)
        }.value
    }

    func performAsyncBackgroundTask<T>(_ task: @escaping (ModelContext) async -> T) async -> T {
        return await Task.detached {
            let context = await ModelContext(ArgusApp.sharedModelContainer)
            return await task(context)
        }.value
    }
}
