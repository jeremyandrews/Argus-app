import SwiftUI

struct ErrorWrapper: Identifiable {
    let id = UUID()
    let message: String
}

struct SubscriptionsView: View {
    @State private var subscriptions: [String: Bool] = [:]
    @State private var jwtToken: String? = nil
    @State private var errorMessage: ErrorWrapper? = nil
    @State private var isFirstLaunch: Bool = true

    let listOfSubscriptions: [String] = ["Alert", "Apple", "Bitcoins", "Clients", "Drupal", "E-Ink", "EVs", "Global", "LLMs", "Longevity", "Music", "Rust", "Space", "Tuscany", "Vulnerability", "Test"]
    let defaultAutoSubscriptions: [String] = ["Apple", "Bitcoins", "Drupal", "EVs", "Global", "LLMs", "Space", "Vulnerability"]

    var body: some View {
        NavigationView {
            List {
                ForEach(listOfSubscriptions, id: \.self) { subscription in
                    let isSelected = subscriptions[subscription] ?? false
                    Button(action: {
                        toggleSubscription(subscription, isSelected: isSelected)
                    }) {
                        HStack {
                            Text(subscription)
                                .foregroundColor(isSelected ? .blue : .gray)
                            Spacer()
                            Image(systemName: isSelected ? "checkmark" : "xmark")
                                .foregroundColor(isSelected ? .blue : .gray)
                        }
                        .listRowBackground(isSelected ? Color.clear : Color.gray.opacity(0.2))
                    }
                }
            }
            .navigationTitle("Subscriptions")
            .onAppear {
                authenticateAndLoadSubscriptions()
            }
            .alert(item: $errorMessage) { error in
                Alert(title: Text("Error"), message: Text(error.message), dismissButton: .default(Text("OK")))
            }
        }
    }

    private func authenticateAndLoadSubscriptions() {
        Task {
            do {
                jwtToken = try await authenticateDevice()
                subscriptions = loadSubscriptions()

                // Check if it's the first launch and auto-subscribe
                if isFirstLaunch {
                    isFirstLaunch = false
                    autoSubscribeToDefaultTopics()
                }
            } catch {
                errorMessage = ErrorWrapper(message: "Failed to authenticate: \(error.localizedDescription)")
            }
        }
    }

    private func autoSubscribeToDefaultTopics() {
        Task {
            for topic in defaultAutoSubscriptions {
                guard subscriptions[topic] == false else { continue }
                do {
                    try await performAPIRequest { try await subscribeToTopic(topic, token: $0) }
                    subscriptions[topic] = true
                } catch {
                    errorMessage = ErrorWrapper(message: "Failed to auto-subscribe to \(topic): \(error.localizedDescription)")
                }
            }
            saveSubscriptions(subscriptions)
        }
    }

    private func toggleSubscription(_ topic: String, isSelected: Bool) {
        guard jwtToken != nil else {
            errorMessage = ErrorWrapper(message: "Not authenticated. Please try again.")
            return
        }

        Task {
            do {
                if isSelected {
                    try await performAPIRequest { try await unsubscribeFromTopic(topic, token: $0) }
                } else {
                    try await performAPIRequest { try await subscribeToTopic(topic, token: $0) }
                }
                subscriptions[topic] = !isSelected
                saveSubscriptions(subscriptions)
            } catch {
                errorMessage = ErrorWrapper(message: "Failed to update subscription for \(topic): \(error.localizedDescription)")
            }
        }
    }

    private func authenticateDevice() async throws -> String {
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

    private func performAPIRequest(apiCall: (String) async throws -> Void) async throws {
        do {
            guard let token = jwtToken else { throw URLError(.userAuthenticationRequired) }
            try await apiCall(token)
        } catch {
            if let urlError = error as? URLError, urlError.code == .userAuthenticationRequired {
                jwtToken = try await authenticateDevice()
                guard let newToken = jwtToken else { throw URLError(.userAuthenticationRequired) }
                try await apiCall(newToken)
            } else {
                throw error
            }
        }
    }

    private func subscribeToTopic(_ topic: String, token: String) async throws {
        let url = URL(string: "https://api.arguspulse.com/subscribe")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["topic": topic])

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
                throw URLError(.userAuthenticationRequired)
            }
            throw URLError(.badServerResponse)
        }
    }

    private func unsubscribeFromTopic(_ topic: String, token: String) async throws {
        let url = URL(string: "https://api.arguspulse.com/unsubscribe")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["topic": topic])

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
                throw URLError(.userAuthenticationRequired)
            }
            throw URLError(.badServerResponse)
        }
    }

    private func loadSubscriptions() -> [String: Bool] {
        let defaults = UserDefaults.standard
        let subscriptionString = defaults.string(forKey: "subscriptions") ?? ""
        var subscriptions: [String: Bool] = [:]

        if !subscriptionString.isEmpty {
            let components = subscriptionString.components(separatedBy: ",")
            for component in components {
                let parts = component.components(separatedBy: ":")
                if parts.count == 2 {
                    subscriptions[parts[0]] = parts[1] == "true"
                }
            }
        } else {
            for topic in listOfSubscriptions {
                subscriptions[topic] = false
            }
        }

        return subscriptions
    }

    private func saveSubscriptions(_ subscriptions: [String: Bool]) {
        let defaults = UserDefaults.standard
        var subscriptionString = ""

        for (topic, isEnabled) in subscriptions {
            if !subscriptionString.isEmpty {
                subscriptionString += ","
            }
            subscriptionString += "\(topic):\(isEnabled)"
        }

        defaults.set(subscriptionString, forKey: "subscriptions")
    }
}
