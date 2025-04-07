import Foundation
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
        configuration.timeoutIntervalForRequest = 10.0 // 10 seconds for initial connection
        configuration.timeoutIntervalForResource = 30.0 // 30 seconds for the entire resource
        session = URLSession(configuration: configuration)
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

    /// Fetches articles from the server
    /// - Parameters:
    ///   - limit: Maximum number of articles to fetch
    ///   - topic: Optional topic filter
    ///   - since: Optional date to fetch articles published after
    /// - Returns: Array of ArticleJSON objects
    /// - Throws: ApiError if fetch fails
    func fetchArticles(limit: Int = 50, topic: String? = nil, since: Date? = nil) async throws -> [ArticleJSON] {
        var queryItems = [URLQueryItem(name: "limit", value: "\(limit)")]

        if let topic = topic {
            queryItems.append(URLQueryItem(name: "topic", value: topic))
        }

        if let since = since {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            queryItems.append(URLQueryItem(name: "since", value: formatter.string(from: since)))
        }

        var urlComponents = URLComponents(string: baseURL + "/articles")!
        urlComponents.queryItems = queryItems

        guard let url = urlComponents.url else {
            throw ApiError.invalidURL
        }

        return try await performAuthenticatedRequestWithDecoding(to: url, method: "GET") { data in
            // First try to decode as an array directly
            do {
                let jsonObjects = try JSONSerialization.jsonObject(with: data) as? [Any]

                // Check if this is a dictionary response with an articles key
                if let jsonObjects = jsonObjects {
                    return try self.processArticleArray(jsonObjects)
                } else if let jsonDict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let articlesArray = jsonDict["articles"] as? [Any]
                {
                    return try self.processArticleArray(articlesArray)
                } else {
                    self.logger.error("Unexpected response format for articles")
                    throw ApiError.invalidResponse
                }
            } catch {
                self.logger.error("Error parsing article JSON: \(error.localizedDescription)")
                throw ApiError.decodingError(error)
            }
        }
    }

    /// Fetches a specific article by ID
    /// - Parameter id: The UUID of the article to fetch
    /// - Returns: ArticleJSON object
    /// - Throws: ApiError if fetch fails
    func fetchArticle(by id: UUID) async throws -> ArticleJSON {
        let url = URL(string: baseURL + "/articles/\(id.uuidString)")!

        return try await performAuthenticatedRequestWithDecoding(to: url, method: "GET") { data in
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
                throw ApiError.decodingError(error)
            }
        }
    }

    /// Fetches an article by its JSON URL
    /// - Parameter jsonURL: Full URL to the article JSON
    /// - Returns: ArticleJSON object
    /// - Throws: ApiError if fetch fails
    func fetchArticleByURL(jsonURL: String) async throws -> ArticleJSON {
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
                throw ApiError.decodingError(error)
            }
        }
    }

    /// Sync viewed articles with the server and get unseen articles
    /// - Parameter seenArticles: Array of recently seen article JSON URLs
    /// - Returns: Array of unseen article URLs
    /// - Throws: ApiError if sync fails
    func syncArticles(seenArticles: [String]) async throws -> [String] {
        let url = URL(string: baseURL + "/articles/sync")!
        let payload = ["seen_articles": seenArticles]

        return try await performAuthenticatedRequestWithDecoding(to: url, method: "POST", body: payload) { data in
            do {
                let response = try JSONDecoder().decode([String: [String]].self, from: data)
                return response["unseen_articles"] ?? []
            } catch {
                self.logger.error("Error decoding sync response: \(error.localizedDescription)")
                throw ApiError.decodingError(error)
            }
        }
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

        logger.info("Response status code: \(httpResponse.statusCode)")

        switch httpResponse.statusCode {
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
