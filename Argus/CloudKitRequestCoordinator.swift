import Foundation
import CloudKit

/// Centralizes CloudKit request handling to prevent conflicts and manage request flow
actor CloudKitRequestCoordinator {
    /// Singleton instance for easy access
    static let shared = CloudKitRequestCoordinator()
    
    /// Types of CloudKit operations for request management
    enum RequestType: String, CaseIterable {
        case export
        case import_
        case setup
        case fetch
        case modify
        case unknown
    }
    
    /// Represents a CloudKit request with metadata
    struct Request: Identifiable {
        let id: UUID
        let type: RequestType
        let priority: Int
        let description: String
        let creationDate: Date
        var isActive = false
        let operation: CKOperation?
        
        init(type: RequestType, 
             priority: Int = 1, 
             description: String = "",
             operation: CKOperation? = nil) {
            self.id = UUID()
            self.type = type
            self.priority = priority
            self.description = description
            self.creationDate = Date()
            self.operation = operation
        }
    }
    
    /// Tracks pending requests by type
    private var pendingRequests: [RequestType: [Request]] = [:]
    
    /// Tracks currently active requests by type
    private var activeRequests: [RequestType: Request] = [:]
    
    /// Tracks all operations for monitoring and cancellation
    private var operations: [UUID: CKOperation] = [:]
    
    /// CKContainer for operations
    private let container: CKContainer
    
    /// Initialize with container identifier
    init(containerIdentifier: String = "iCloud.com.andrews.Argus.Argus") {
        self.container = CKContainer(identifier: containerIdentifier)
        
        // Initialize request queues
        for type in RequestType.allCases {
            pendingRequests[type] = []
        }
    }
    
    /// Schedules a CloudKit operation
    /// - Parameters:
    ///   - operation: The CKOperation to execute
    ///   - type: The type of request
    ///   - priority: Priority level (higher numbers = higher priority)
    ///   - description: Description for logging
    /// - Returns: The request ID for tracking
    @discardableResult
    func scheduleOperation<T: CKOperation>(_ operation: T, 
                                           type: RequestType, 
                                           priority: Int = 1, 
                                           description: String = "") async -> UUID {
        
        // Create request
        let request = Request(
            type: type,
            priority: priority,
            description: description.isEmpty ? String(describing: operation) : description,
            operation: operation
        )
        
        // Configure operation for optimal battery performance
        configureOperation(operation)
        
        // Store the operation
        operations[request.id] = operation
        
        ModernizationLogger.log(.debug, component: .cloudKit,
            message: "Scheduling \(type.rawValue) request: \(request.description)")
        
        // Check if we can execute immediately
        if activeRequests[type] == nil {
            await executeRequest(request)
        } else {
            // Add to pending queue
            pendingRequests[type]?.append(request)
            
            // Sort by priority
            pendingRequests[type]?.sort { $0.priority > $1.priority }
            
            ModernizationLogger.log(.debug, component: .cloudKit,
                message: "Queued \(type.rawValue) request - \(pendingRequests[type]?.count ?? 0) pending")
        }
        
        return request.id
    }
    
    /// Executes a CloudKit request, handling completion and errors
    private func executeRequest(_ request: Request) async {
        guard let operation = request.operation else {
            ModernizationLogger.log(.warning, component: .cloudKit,
                message: "Cannot execute request without operation: \(request.id)")
            await processNextRequest(for: request.type)
            return
        }
        
        // Mark as active
        activeRequests[request.type] = request
        
        ModernizationLogger.log(.debug, component: .cloudKit,
            message: "Executing \(request.type.rawValue) request: \(request.description)")
        
        // Execute the operation and wait for completion
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Create an operation completion handler
                let completionHandler: (Error?) -> Void = { error in
                    if let error = error {
                        ModernizationLogger.logCloudKitError(
                            operation: "CloudKit \(request.type.rawValue) operation",
                            error: error
                        )
                        continuation.resume(throwing: error)
                    } else {
                        ModernizationLogger.log(.debug, component: .cloudKit,
                            message: "Successfully completed \(request.type.rawValue) request")
                        continuation.resume()
                    }
                }
                
                // Set up operation with proper completion handler
                if let fetchRecordsOp = operation as? CKFetchRecordsOperation {
                    // Store original completion
                    let originalCompletion = fetchRecordsOp.fetchRecordsResultBlock
                    
                    // Set new completion
                    fetchRecordsOp.fetchRecordsResultBlock = { result in
                        // Call original if exists
                        originalCompletion?(result)
                        
                        // Continue our handler
                        switch result {
                        case .success:
                            completionHandler(nil)
                        case .failure(let error):
                            completionHandler(error)
                        }
                    }
                    
                    container.privateCloudDatabase.add(fetchRecordsOp)
                } else if let modifyRecordsOp = operation as? CKModifyRecordsOperation {
                    // Store original completion
                    let originalCompletion = modifyRecordsOp.modifyRecordsResultBlock
                    
                    // Set new completion
                    modifyRecordsOp.modifyRecordsResultBlock = { result in
                        // Call original if exists
                        originalCompletion?(result)
                        
                        // Continue our handler
                        switch result {
                        case .success:
                            completionHandler(nil)
                        case .failure(let error):
                            completionHandler(error)
                        }
                    }
                    
                    container.privateCloudDatabase.add(modifyRecordsOp)
                } else if let queryOp = operation as? CKQueryOperation {
                    // Use completion handler
                    let originalCompletion = queryOp.queryResultBlock
                    
                    queryOp.queryResultBlock = { result in
                        // Call original if exists
                        originalCompletion?(result)
                        
                        // Continue our handler
                        switch result {
                        case .success:
                            completionHandler(nil)
                        case .failure(let error):
                            completionHandler(error)
                        }
                    }
                    
                    container.privateCloudDatabase.add(queryOp)
                } else {
                    // For other operations, we'll have to set a custom completion block
                    // and infer success/failure from that
                    let originalCompletion = operation.completionBlock
                    
                    operation.completionBlock = {
                        // Call original completion if present
                        originalCompletion?()
                        
                        // We don't have an error to check, so assume success
                        // This isn't ideal but it's the best we can do for generic CKOperations
                        continuation.resume()
                    }
                    
                    container.add(operation)
                }
            }
            
            // Operation completed successfully
            notifyRequestSuccess(request)
        } catch {
            // Operation failed
            notifyRequestFailure(request, error: error)
        }
        
        // Clean up
        operations.removeValue(forKey: request.id)
        activeRequests.removeValue(forKey: request.type)
        
        // Process next request
        await processNextRequest(for: request.type)
    }
    
    /// Process the next pending request for a specific type
    private func processNextRequest(for type: RequestType) async {
        if let nextRequest = pendingRequests[type]?.first {
            // Remove from pending queue
            pendingRequests[type]?.removeFirst()
            
            // Execute next request
            await executeRequest(nextRequest)
        }
    }
    
    /// Cancels a specific operation by ID
    func cancelOperation(withId id: UUID) {
        if let operation = operations[id] {
            operation.cancel()
            operations.removeValue(forKey: id)
            
            ModernizationLogger.log(.debug, component: .cloudKit,
                message: "Cancelled operation \(id)")
        }
    }
    
    /// Cancels all operations of a specific type
    func cancelOperations(ofType type: RequestType?) async {
        // Find operations to cancel
        if let type = type {
            // Cancel active request of this type
            if let activeRequest = activeRequests[type], 
               let operation = operations[activeRequest.id] {
                operation.cancel()
                operations.removeValue(forKey: activeRequest.id)
                activeRequests.removeValue(forKey: type)
            }
            
            // Clear pending queue for this type
            pendingRequests[type]?.removeAll()
            
            ModernizationLogger.log(.debug, component: .cloudKit,
                message: "Cancelled all \(type.rawValue) operations")
        } else {
            // Cancel all operations
            for operation in operations.values {
                operation.cancel()
            }
            
            // Clear all queues
            operations.removeAll()
            activeRequests.removeAll()
            for type in RequestType.allCases {
                pendingRequests[type]?.removeAll()
            }
            
            ModernizationLogger.log(.warning, component: .cloudKit,
                message: "Cancelled ALL CloudKit operations")
        }
    }
    
    /// Notifies about a successful request
    private func notifyRequestSuccess(_ request: Request) {
        // Notify the health monitor to track successful operations
        Task {
            CloudKitHealthMonitor.shared?.recordSuccess()
        }
    }
    
    /// Notifies about a failed request
    private func notifyRequestFailure(_ request: Request, error: Error) {
        // Log the error
        ModernizationLogger.logCloudKitError(
            operation: "CloudKit \(request.type.rawValue) operation",
            error: error,
            detail: request.description
        )
        
        // Notify the health monitor to track failures
        Task {
            CloudKitHealthMonitor.shared?.recordFailure(error: error)
        }
    }
    
    /// Configures a CloudKit operation for optimal power efficiency
    private func configureOperation<T: CKOperation>(_ operation: T) {
        // Set quality of service based on thermal state
        let thermalState = ProcessInfo.processInfo.thermalState
        
        // Compare thermal states using raw values
        if thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            // Low power mode - lowest priority
            operation.configuration.qualityOfService = .utility
            operation.configuration.isLongLived = false
        } else if thermalState == .fair {
            // Normal mode - default priority
            operation.configuration.qualityOfService = .default
            operation.configuration.isLongLived = true
        } else {
            // Good thermal state - higher priority
            operation.configuration.qualityOfService = .userInitiated
            operation.configuration.isLongLived = true
        }
        
        // Set reasonable timeouts
        operation.configuration.timeoutIntervalForRequest = 30
        operation.configuration.timeoutIntervalForResource = 60
    }
}

// Static accessor for the shared health monitor
extension CloudKitHealthMonitor {
    static var shared: CloudKitHealthMonitor?
}
