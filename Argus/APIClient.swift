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
        return token
    }

    func performAuthenticatedRequest<T: Codable>(to url: URL, method: String = "POST", body: T? = nil) async throws -> Data {
        guard let token = UserDefaults.standard.string(forKey: "jwtToken") else {
            throw URLError(.userAuthenticationRequired)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body = body {
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
                throw URLError(.userAuthenticationRequired)
            }
            throw URLError(.badServerResponse)
        }
        return data
    }
}
