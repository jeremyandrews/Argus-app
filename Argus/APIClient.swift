import Foundation
import Network
import OSLog
import SwiftData
import SwiftUI

/// Comprehensive API client for the Argus backend
class APIClient {
    static let shared = APIClient()

    /// Base URL for the API
    private let baseURL = "https://api.arguspulse.com"

    /// Custom URLSession with proper timeout configuration
    private let session: URLSession

    /// Logger for API operations
    private let logger = AppLogger.api

    /// Network path monitor for connectivity status
    private let networkMonitor = NWPathMonitor()

    /// Current network path status
    private var currentPath: NWPath?

    /// Maximum number of retries for a request
    private let maxRetries = 3

    /// API-specific error types
    enum ApiError: Error, LocalizedError {
        case invalidURL
        case authenticationRequired
        case invalidResponse
        case serverError(statusCode: Int, message: String?)
        case decodingError(Error)
        case networkError(Error)
        case rateLimited(retryAfter: TimeInterval?)
        case resourceNotFound
        case requestTimeout
        case unknown(Error)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid URL format"
            case .authenticationRequired:
                return "Authentication required or token expired"
            case .invalidResponse:
                return "Invalid or unexpected server response"
            case let .serverError(code, message):
                return "Server error (\(code)): \(message ?? "Unknown error")"
            case let .decodingError(error):
                return "Failed to decode response: \(error.localizedDescription)"
            case let .networkError(error):
                return "Network error: \(error.localizedDescription)"
            case let .rateLimited(retryAfter):
                if let seconds = retryAfter {
                    return "Rate limited. Retry after \(Int(seconds)) seconds"
                }
                return "Rate limited. Please try again later"
            case .resourceNotFound:
                return "The requested resource was not found"
            case .requestTimeout:
                return "Request timed out"
            case let .unknown(error):
                return "Unknown error: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Initialization

    private init() {
        // Configure timeouts at initialization
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15.0 // 15 seconds for initial connection (increased from 10)
        configuration.timeoutIntervalForResource = 60.0 // 60 seconds for the entire resource (increased from 30)
        session = URLSession(configuration: configuration)

        // Start monitoring network status
        setupNetworkMonitoring()
    }

    // MARK: - Network Monitoring

    /// Set up network path monitoring
    private func setupNetworkMonitoring() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            self?.currentPath = path

            let statusDescription = path.status == .satisfied ? "connected" : "disconnected"
            let interfaceTypes = path.availableInterfaces.map { interface -> String in
                // Need to capture self strongly here for the mapping function
                guard let self = self else { return "Unknown" }
                return self.interfaceTypeToString(interface.type)
            }.joined(separator: ", ")

            if path.status == .satisfied {
                ModernizationLogger.log(.info, component: .apiClient,
                                        message: "Network connection: \(statusDescription) using \(interfaceTypes)")
            } else {
                ModernizationLogger.log(.warning, component: .apiClient,
                                        message: "Network connection: \(statusDescription). No internet access.")
            }
        }

        // Start monitoring on a background queue
        networkMonitor.start(queue: DispatchQueue.global(qos: .background))
    }

    /// Check if the device has network connectivity
    var isNetworkConnected: Bool {
        return currentPath?.status == .satisfied
    }

    /// Check if the device is on WiFi
    var isOnWifi: Bool {
        return currentPath?.usesInterfaceType(.wifi) ?? false
    }

    // MARK: - Authentication

    /// Authenticates the device with the backend server
    /// - Returns: JWT token for subsequent requests
    /// - Throws: APIError if authentication fails
    func authenticateDevice() async throws -> String {
        guard let deviceToken = UserDefaults.standard.string(forKey: "deviceToken") else {
            throw ApiError.authenticationRequired
        }

        let endpoint = "/authenticate"
        let url = URL(string: baseURL + endpoint)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["device_id": deviceToken])

        do {
            let (data, response) = try await session.data(for: request)
            try validateHTTPResponse(response, data: data)

            let jsonResponse = try JSONDecoder().decode([String: String].self, from: data)
            guard let token = jsonResponse["token"] else {
                throw ApiError.invalidResponse
            }

            UserDefaults.standard.set(token, forKey: "jwtToken") // Save the new token
            logger.info("Device authentication successful")
            return token
        } catch let error as ApiError {
            self.logger.error("Authentication failed: \(error.localizedDescription)")
            throw error
        } catch {
            logger.error("Unexpected error during authentication: \(error.localizedDescription)")
            throw mapError(error)
        }
    }

    // MARK: - Article APIs

    /// Fetches articles from the server using the sync endpoint
    /// - Parameters:
    ///   - limit: Maximum number of articles to fetch (note: may be ignored by server)
    ///   - topic: Optional topic filter (note: may be ignored by server)
    ///   - since: Optional date filter (note: may be ignored by server)
    ///   - allowRetries: Whether to retry on network failures
    /// - Returns: Array of ArticleJSON objects
    /// - Throws: ApiError if fetch fails
    func fetchArticles(limit: Int = 50, topic _: String? = nil, since _: Date? = nil,
                       allowRetries: Bool = true) async throws -> [ArticleJSON]
    {
        // Note: The backend only supports the /articles/sync endpoint, not /articles
        // The parameters (limit, topic, since) are kept for backward compatibility
        // but won't be used by the server.

        ModernizationLogger.log(.info, component: .apiClient,
                                message: "Fetching articles using the articles/sync endpoint")

        // We need to get a list of article URLs first
        let articleURLs = try await fetchArticleURLs(allowRetries: allowRetries)

        if articleURLs.isEmpty {
            ModernizationLogger.log(.info, component: .apiClient,
                                    message: "No article URLs returned from sync endpoint")
            return []
        }

        ModernizationLogger.log(.info, component: .apiClient,
                                message: "Retrieved \(articleURLs.count) article URLs, fetching content...")

        // For each URL, fetch the actual article
        var articles: [ArticleJSON] = []

        for url in articleURLs.prefix(limit) { // Honor the limit parameter locally
            do {
                if let article = try await fetchArticleByURL(jsonURL: url, allowEmptyResponse: true, allowRetries: allowRetries) {
                    articles.append(article)

                    // Check if we've hit the limit
                    if articles.count >= limit {
                        break
                    }
                }
            } catch {
                // Log the error but continue with other articles
                logger.error("Error fetching article at URL \(url): \(error)")
                ModernizationLogger.log(.error, component: .apiClient,
                                        message: "Error fetching article at URL \(url): \(error)")
            }
        }

        return articles
    }

    /// Fetches only the URLs of available articles from the server
    /// - Parameter allowRetries: Whether to retry on network failures
    /// - Returns: Array of article JSON URLs
    /// - Throws: ApiError if fetch fails
    private func fetchArticleURLs(allowRetries: Bool = true) async throws -> [String] {
        // Query the database for existing articles to avoid requesting content we already have
        do {
            // Get access to the SwiftData container
            let container = SwiftDataContainer.shared.container
            let context = ModelContext(container)
            
            // Calculate timestamp from 12 hours ago
            let twelveHoursAgo = Calendar.current.date(byAdding: .hour, value: -12, to: Date()) ?? Date()
            
            // Create a fetch descriptor for ArticleModel to get recently added articles
            let descriptor = FetchDescriptor<ArticleModel>(
                predicate: #Predicate { $0.addedDate >= twelveHoursAgo }
            )
            
            // Fetch articles from the last 12 hours
            let recentArticles = try context.fetch(descriptor)
            
            // Extract the jsonURL values (skip empty ones)
            let seenArticleURLs = recentArticles.compactMap { $0.jsonURL.isEmpty ? nil : $0.jsonURL }
            
            ModernizationLogger.log(.info, component: .apiClient,
                                  message: "Syncing with \(seenArticleURLs.count) articles from last 12 hours")
            
            // If we have too many, limit to avoid excessive payload size
            let limitedURLs = seenArticleURLs.count > 200 ? Array(seenArticleURLs.prefix(200)) : seenArticleURLs
            
            // Use these URLs as our seen_articles list
            return try await syncArticles(seenArticles: limitedURLs, allowRetries: allowRetries)
        } catch {
            AppLogger.api.error("Error fetching article URLs from database: \(error)")
            ModernizationLogger.log(.warning, component: .apiClient,
                                  message: "Database query failed, falling back to empty seen_articles list")
            
            // Fall back to empty list if database query fails
            return try await syncArticles(seenArticles: [], allowRetries: allowRetries)
        }
    }

    /// Fetches a specific article by ID
    /// - Parameters:
    ///   - id: The UUID of the article to fetch
    ///   - allowEmptyResponse: If true, returns nil instead of throwing for 404 errors
    ///   - allowRetries: Whether to allow automatic retries for network failures
    /// - Returns: ArticleJSON object or nil if allowEmptyResponse is true and article not found
    /// - Throws: ApiError if fetch fails
    func fetchArticle(by id: UUID, allowEmptyResponse: Bool = false, allowRetries: Bool = true) async throws -> ArticleJSON? {
        let url = URL(string: baseURL + "/articles/\(id.uuidString)")!

        do {
            return try await performAuthenticatedRequestWithDecoding(to: url, method: "GET") { data in
                ModernizationLogger.log(.debug, component: .apiClient,
                                        message: "Decoding article with ID: \(id.uuidString)")

                do {
                    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        throw ApiError.invalidResponse
                    }

                    // Ensure the json_url is set in case it's missing from server response
                    var enrichedJson = json
                    if enrichedJson["json_url"] == nil {
                        enrichedJson["json_url"] = "/articles/\(id.uuidString).json"
                    }

                    guard let articleJSON = processArticleJSON(enrichedJson) else {
                        throw ApiError.invalidResponse
                    }

                    return articleJSON
                } catch {
                    self.logger.error("Error decoding article JSON: \(error.localizedDescription)")
                    ModernizationLogger.log(.error, component: .apiClient,
                                            message: "Error decoding article JSON: \(error.localizedDescription)")
                    throw ApiError.decodingError(error)
                }
            }
        } catch ApiError.resourceNotFound where allowEmptyResponse {
            // Return nil instead of throwing for 404 errors if allowEmptyResponse is true
            ModernizationLogger.log(.warning, component: .apiClient,
                                    message: "Article with ID \(id.uuidString) not found. Returning nil.")
            return nil
        } catch let error as ApiError where allowRetries {
            if case .networkError = error, isNetworkConnected {
                ModernizationLogger.log(.warning, component: .apiClient,
                                        message: "Network error fetching article with ID \(id.uuidString). Will retry: \(error.localizedDescription)")
                // Retry with exponential backoff
                return try await retryWithBackoff { [weak self] in
                    guard let self = self else { throw ApiError.unknown(NSError(domain: "com.argus", code: -1)) }
                    // Retry without allowing further retries to prevent infinite recursion
                    return try await self.fetchArticle(by: id, allowEmptyResponse: allowEmptyResponse, allowRetries: false)
                }
            }
            throw error
        }
    }

    /// Fetches an article by its JSON URL
    /// - Parameters:
    ///   - jsonURL: Full URL to the article JSON
    ///   - allowEmptyResponse: If true, returns nil instead of throwing for 404 errors
    ///   - allowRetries: Whether to allow automatic retries for network failures
    /// - Returns: ArticleJSON object or nil if allowEmptyResponse is true and article not found
    /// - Throws: ApiError if fetch fails
    func fetchArticleByURL(jsonURL: String, allowEmptyResponse: Bool = false, allowRetries: Bool = true) async throws -> ArticleJSON? {
        // Determine if this is a full URL or just a path
        let url: URL
        if jsonURL.hasPrefix("http") {
            guard let validURL = URL(string: jsonURL) else {
                throw ApiError.invalidURL
            }
            url = validURL
        } else {
            // Treat as a path that should be appended to baseURL
            let path = jsonURL.hasPrefix("/") ? jsonURL : "/" + jsonURL
            guard let validURL = URL(string: baseURL + path) else {
                throw ApiError.invalidURL
            }
            url = validURL
        }

        ModernizationLogger.log(.debug, component: .apiClient,
                                message: "Fetching article by URL: \(jsonURL)")

        do {
            return try await performAuthenticatedRequestWithDecoding(to: url, method: "GET") { data in
                do {
                    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        throw ApiError.invalidResponse
                    }

                    // Ensure the json_url is set
                    var enrichedJson = json
                    if enrichedJson["json_url"] == nil {
                        enrichedJson["json_url"] = jsonURL
                    }

                    guard let articleJSON = processArticleJSON(enrichedJson) else {
                        throw ApiError.invalidResponse
                    }

                    return articleJSON
                } catch {
                    self.logger.error("Error decoding article JSON for URL \(jsonURL): \(error.localizedDescription)")
                    ModernizationLogger.log(.error, component: .apiClient,
                                            message: "Error decoding article JSON for URL \(jsonURL): \(error.localizedDescription)")
                    throw ApiError.decodingError(error)
                }
            }
        } catch ApiError.resourceNotFound where allowEmptyResponse {
            // Return nil instead of throwing for 404 errors if allowEmptyResponse is true
            ModernizationLogger.log(.warning, component: .apiClient,
                                    message: "Article with URL \(jsonURL) not found. Returning nil.")
            return nil
        } catch let error as ApiError where allowRetries {
            if case .networkError = error, isNetworkConnected {
                ModernizationLogger.log(.warning, component: .apiClient,
                                        message: "Network error fetching article with URL \(jsonURL). Will retry: \(error.localizedDescription)")
                // Retry with exponential backoff
                return try await retryWithBackoff { [weak self] in
                    guard let self = self else { throw ApiError.unknown(NSError(domain: "com.argus", code: -1)) }
                    // Retry without allowing further retries to prevent infinite recursion
                    return try await self.fetchArticleByURL(jsonURL: jsonURL, allowEmptyResponse: allowEmptyResponse, allowRetries: false)
                }
            }
            throw error
        }
    }

    /// Sync viewed articles with the server and get unseen articles
    /// - Parameters:
    ///   - seenArticles: Array of recently seen article JSON URLs
    ///   - allowRetries: Whether to allow automatic retries for network failures
    /// - Returns: Array of unseen article URLs (empty array if sync fails with 404)
    /// - Throws: ApiError if sync fails with other errors
    func syncArticles(seenArticles: [String], allowRetries: Bool = true) async throws -> [String] {
        let url = URL(string: baseURL + "/articles/sync")!
        let payload = ["seen_articles": seenArticles]

        ModernizationLogger.log(.debug, component: .apiClient,
                                message: "Syncing \(seenArticles.count) articles with server")

        do {
            return try await performAuthenticatedRequestWithDecoding(to: url, method: "POST", body: payload) { data in
                do {
                    let response = try JSONDecoder().decode([String: [String]].self, from: data)
                    let unseenArticles = response["unseen_articles"] ?? []
                    ModernizationLogger.log(.info, component: .apiClient,
                                            message: "Sync successful. Found \(unseenArticles.count) unseen articles.")
                    return unseenArticles
                } catch {
                    self.logger.error("Error decoding sync response: \(error.localizedDescription)")
                    ModernizationLogger.log(.error, component: .apiClient,
                                            message: "Error decoding sync response: \(error.localizedDescription)")
                    throw ApiError.decodingError(error)
                }
            }
        } catch ApiError.resourceNotFound {
            // Return empty array instead of throwing for 404 errors
            ModernizationLogger.log(.warning, component: .apiClient,
                                    message: "Sync endpoint not found (404). Returning empty array.")
            return []
        } catch let error as ApiError where allowRetries {
            if case .networkError = error, isNetworkConnected {
                ModernizationLogger.log(.warning, component: .apiClient,
                                        message: "Network error during sync. Will retry: \(error.localizedDescription)")
                // Retry with exponential backoff
                return try await retryWithBackoff { [weak self] in
                    guard let self = self else { throw ApiError.unknown(NSError(domain: "com.argus", code: -1)) }
                    // Retry without allowing further retries to prevent infinite recursion
                    return try await self.syncArticles(seenArticles: seenArticles, allowRetries: false)
                }
            }
            throw error
        }
    }

    // MARK: - Retry Logic

    /// Retry a block with exponential backoff
    /// - Parameters:
    ///   - maxAttempts: Maximum number of retry attempts
    ///   - block: The async operation to retry
    /// - Returns: The result of the operation
    /// - Throws: The last error encountered if all retries fail
    private func retryWithBackoff<T>(maxAttempts: Int = 3, block: @escaping () async throws -> T) async throws -> T {
        var lastError: Error?

        for attempt in 1 ... maxAttempts {
            do {
                // Wait with exponential backoff before retrying
                if attempt > 1 {
                    let backoffSeconds = Double(Swift.min(2 << (attempt - 2), 30))
                    ModernizationLogger.log(.info, component: .apiClient,
                                            message: "Retry attempt \(attempt)/\(maxAttempts) after \(backoffSeconds)s backoff")
                    try await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))
                }

                // If we lost network connectivity while waiting for retry, throw immediately
                if attempt > 1 && !isNetworkConnected {
                    ModernizationLogger.log(.warning, component: .apiClient,
                                            message: "Aborting retry - no network connectivity")
                    throw ApiError.networkError(URLError(.notConnectedToInternet))
                }

                return try await block()
            } catch {
                lastError = error

                // If this is a fatal error that won't be fixed by retrying, don't retry
                if let apiError = error as? ApiError {
                    switch apiError {
                    case .authenticationRequired, .invalidURL, .decodingError, .resourceNotFound:
                        // These errors won't be fixed by retrying
                        throw error
                    default:
                        // Other errors might be temporary, continue with retry
                        ModernizationLogger.log(.warning, component: .apiClient,
                                                message: "Retry attempt \(attempt) failed: \(error.localizedDescription)")
                    }
                }
            }
        }

        ModernizationLogger.log(.error, component: .apiClient,
                                message: "All retry attempts failed")
        throw lastError ?? ApiError.unknown(NSError(domain: "com.argus", code: -1))
    }

    // MARK: - Helper Methods

    /// Performs an authenticated request and decodes the response
    /// - Parameters:
    ///   - url: The URL to send the request to
    ///   - method: HTTP method (GET, POST, etc.)
    ///   - body: Optional body for the request
    ///   - decoder: Closure that decodes the response data
    /// - Returns: Decoded value of type T
    /// - Throws: ApiError if request fails
    private func performAuthenticatedRequestWithDecoding<T, B: Encodable>(
        to url: URL,
        method: String = "GET",
        body: B? = nil,
        decoder: @escaping (Data) throws -> T
    ) async throws -> T {
        do {
            // Try with existing token first
            if let token = UserDefaults.standard.string(forKey: "jwtToken") {
                do {
                    let data = try await sendRequest(to: url, method: method, token: token, body: body)
                    return try decoder(data)
                } catch ApiError.authenticationRequired {
                    // Token is invalid or expired, re-authenticate
                    logger.info("Token expired. Re-authenticating...")
                }
            }

            // No token or token expired, re-authenticate
            logger.info("No token found or expired. Authenticating...")
            let newToken = try await authenticateDevice()
            let data = try await sendRequest(to: url, method: method, token: newToken, body: body)
            return try decoder(data)
        } catch let error as ApiError {
            self.logger.error("API error during request to \(url): \(error.localizedDescription)")
            throw error
        } catch {
            logger.error("Unexpected error during request to \(url): \(error.localizedDescription)")
            throw mapError(error)
        }
    }

    /// Overload for requests without a body
    private func performAuthenticatedRequestWithDecoding<T>(
        to url: URL,
        method: String = "GET",
        decoder: @escaping (Data) throws -> T
    ) async throws -> T {
        try await performAuthenticatedRequestWithDecoding(to: url, method: method, body: Int?.none, decoder: decoder)
    }

    /// Performs a generic authenticated request
    /// - Parameters:
    ///   - url: The URL to send the request to
    ///   - method: HTTP method (GET, POST, etc.)
    ///   - body: Optional body object to encode as JSON
    /// - Returns: Response data
    /// - Throws: ApiError if request fails
    func performAuthenticatedRequest<T: Encodable>(to url: URL, method: String = "POST", body: T? = nil) async throws -> Data {
        // Try using the current token
        if let token = UserDefaults.standard.string(forKey: "jwtToken") {
            do {
                return try await sendRequest(to: url, method: method, token: token, body: body)
            } catch ApiError.authenticationRequired {
                logger.info("Token expired. Re-authenticating...")
            } catch {
                logger.error("Request failed with error: \(error.localizedDescription)")
                throw error
            }
        }

        // If token is missing or expired, re-authenticate
        logger.info("No token found or expired. Authenticating...")
        let newToken = try await authenticateDevice()
        return try await sendRequest(to: url, method: method, token: newToken, body: body)
    }

    /// Sends an authenticated request to the specified URL
    /// - Parameters:
    ///   - url: The URL to send the request to
    ///   - method: HTTP method (GET, POST, etc.)
    ///   - token: Authentication token
    ///   - body: Optional body to encode as JSON
    /// - Returns: Response data
    /// - Throws: ApiError if request fails
    private func sendRequest<T: Encodable>(to url: URL, method: String, token: String, body: T?) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        if let body = body {
            let encoder = JSONEncoder()
            request.httpBody = try encoder.encode(body)
        }

        do {
            let (data, response) = try await session.data(for: request)
            try validateHTTPResponse(response, data: data)
            return data
        } catch let error as ApiError {
            throw error
        } catch let error as URLError {
            throw mapURLError(error)
        } catch {
            throw ApiError.unknown(error)
        }
    }

    /// Validates an HTTP response and throws appropriate errors
    /// - Parameters:
    ///   - response: The HTTP response to validate
    ///   - data: Response data for error details
    /// - Throws: ApiError if validation fails
    private func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("Response is not an HTTP response")
            throw ApiError.invalidResponse
        }

        let statusCode = httpResponse.statusCode
        logger.info("Response status code: \(statusCode)")

        // Log more detailed information for important status codes
        switch statusCode {
        case 200 ..< 300:
            ModernizationLogger.log(.debug, component: .apiClient,
                                    message: "Successful response: \(statusCode)")
        case 400 ..< 500:
            ModernizationLogger.log(.warning, component: .apiClient,
                                    message: "Client error response: \(statusCode)")
        case 500 ..< 600:
            ModernizationLogger.log(.error, component: .apiClient,
                                    message: "Server error response: \(statusCode)")
        default:
            ModernizationLogger.log(.warning, component: .apiClient,
                                    message: "Unusual status code: \(statusCode)")
        }

        // Log response headers for debugging
        if statusCode >= 400 {
            let headers = httpResponse.allHeaderFields
            let relevantHeaders = ["Content-Type", "Date", "Retry-After", "X-Request-ID"]
                .compactMap { key in
                    if let value = headers[key] ?? headers[key.lowercased()] {
                        return "\(key): \(value)"
                    }
                    return nil
                }
                .joined(separator: ", ")

            ModernizationLogger.log(.debug, component: .apiClient,
                                    message: "Response headers: \(relevantHeaders)")

            // Try to extract and log error message from response body
            if let errorJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorMessage = errorJSON["message"] as? String
            {
                ModernizationLogger.log(.warning, component: .apiClient,
                                        message: "Error message from server: \(errorMessage)")
            }
        }

        switch statusCode {
        case 200 ..< 300:
            // Success range
            return
        case 401:
            throw ApiError.authenticationRequired
        case 403:
            var errorMessage = "Access forbidden"
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = json["message"] as? String
            {
                errorMessage = message
            }
            throw ApiError.serverError(statusCode: 403, message: errorMessage)
        case 404:
            throw ApiError.resourceNotFound
        case 429:
            // Rate limiting
            var retryAfter: TimeInterval?
            if let retryString = httpResponse.value(forHTTPHeaderField: "Retry-After"),
               let seconds = Double(retryString)
            {
                retryAfter = seconds
            }
            throw ApiError.rateLimited(retryAfter: retryAfter)
        case 500 ..< 600:
            // Server error range
            var errorMessage = "Server error"
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = json["message"] as? String
            {
                errorMessage = message
            }
            throw ApiError.serverError(statusCode: httpResponse.statusCode, message: errorMessage)
        default:
            // Other error codes
            var errorMessage = "Unexpected status code: \(httpResponse.statusCode)"
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = json["message"] as? String
            {
                errorMessage = message
            }
            throw ApiError.serverError(statusCode: httpResponse.statusCode, message: errorMessage)
        }
    }

    /// Maps URLError to ApiError
    /// - Parameter error: The URLError to map
    /// - Returns: Corresponding ApiError
    private func mapURLError(_ error: URLError) -> ApiError {
        switch error.code {
        case .timedOut:
            return .requestTimeout
        case .notConnectedToInternet, .networkConnectionLost:
            return .networkError(error)
        default:
            return .networkError(error)
        }
    }

    /// Helper function to convert NWInterface.InterfaceType to string
    /// - Parameter type: The network interface type
    /// - Returns: String representation of the interface type
    private func interfaceTypeToString(_ type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wifi:
            return "WiFi"
        case .cellular:
            return "Cellular"
        case .wiredEthernet:
            return "Ethernet"
        case .loopback:
            return "Loopback"
        case .other:
            return "Other"
        @unknown default:
            return "Unknown(\(type))"
        }
    }

    /// Maps generic error to ApiError
    /// - Parameter error: The error to map
    /// - Returns: Corresponding ApiError
    private func mapError(_ error: Error) -> ApiError {
        if let urlError = error as? URLError {
            return mapURLError(urlError)
        } else if let apiError = error as? ApiError {
            return apiError
        } else {
            return .unknown(error)
        }
    }

    /// Process an array of article JSON objects
    /// - Parameter jsonArray: Array of article JSON objects
    /// - Returns: Array of ArticleJSON objects
    /// - Throws: ApiError if processing fails
    private func processArticleArray(_ jsonArray: [Any]) throws -> [ArticleJSON] {
        var articles: [ArticleJSON] = []

        for case let json as [String: Any] in jsonArray {
            if let articleJSON = processArticleJSON(json) {
                articles.append(articleJSON)
            } else {
                logger.warning("Failed to process an article in the response")
            }
        }

        if articles.isEmpty, !jsonArray.isEmpty {
            logger.error("Failed to process any articles from response")
            throw ApiError.invalidResponse
        }

        return articles
    }
}
