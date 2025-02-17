import Foundation

class APIClient {
    static let shared = APIClient()
    private init() {}

    func authenticateDevice() async throws -> String {
        guard let deviceToken = UserDefaults.standard.string(forKey: "deviceToken") else {
            throw URLError(.userAuthenticationRequired, userInfo: [NSLocalizedDescriptionKey: "Device token not available."])
        }
        let url = URL(string: "https://api.arguspulse.com/authenticate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["device_id": deviceToken])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let jsonResponse = try JSONDecoder().decode([String: String].self, from: data)
        guard let token = jsonResponse["token"] else {
            throw URLError(.cannotParseResponse)
        }
        UserDefaults.standard.set(token, forKey: "jwtToken") // Save the new token
        return token
    }

    func performAuthenticatedRequest<T: Codable>(to url: URL, method: String = "POST", body: T? = nil) async throws -> Data {
        // Try using the current token
        if let token = UserDefaults.standard.string(forKey: "jwtToken") {
            do {
                return try await sendRequest(to: url, method: method, token: token, body: body)
            } catch {
                if let urlError = error as? URLError, urlError.code == .userAuthenticationRequired {
                    print("Token expired. Re-authenticating...")
                } else {
                    print("Request failed with error: \(error.localizedDescription)")
                    throw error
                }
            }
        }

        // If token is missing or expired, re-authenticate
        print("No token found or expired. Authenticating...")
        let newToken = try await authenticateDevice()
        return try await sendRequest(to: url, method: method, token: newToken, body: body)
    }

    private func sendRequest<T: Codable>(to url: URL, method: String, token: String, body: T?) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        if let body = body {
            let encoder = JSONEncoder()
            request.httpBody = try encoder.encode(body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse {
            print("Response status code: \(httpResponse.statusCode)")

            if httpResponse.statusCode == 401 {
                throw URLError(.userAuthenticationRequired)
            }

            guard httpResponse.statusCode == 200 else {
                if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    print("Server error details: \(errorJson)")
                }
                throw URLError(.badServerResponse)
            }
        }

        return data
    }
}
