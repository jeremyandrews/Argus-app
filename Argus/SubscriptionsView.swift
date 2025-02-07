import SwiftUI

struct SubscriptionsResponse: Codable {
    struct Subscription: Codable {
        let topic: String
        let priority: String
    }

    let subscriptions: [Subscription]
}

struct Subscription: Codable {
    var isSubscribed: Bool
    var isHighPriority: Bool
}

struct ErrorWrapper: Identifiable {
    let id = UUID()
    let message: String
}

private struct Empty: Codable {}

struct SubscriptionsView: View {
    @State private var subscriptions: [String: Subscription] = [:]
    @State private var jwtToken: String? = nil
    @State private var errorMessage: ErrorWrapper? = nil
    @State private var isFirstLaunch: Bool = true
    let listOfSubscriptions: [String] = ["Alert: Direct", "Alert: Near", "Apple", "Bitcoins", "Clients", "Drupal", "E-Ink", "EVs", "Global", "Italy Politics", "LLMs", "Longevity", "Music", "Rust", "Space", "Tuscany", "US Politics", "Vulnerability", "Test"]
    let defaultAutoSubscriptions: [String] = ["Apple", "Bitcoins", "Drupal", "EVs", "Global", "LLMs", "Space", "Vulnerability"]
    private let defaultAlertTopics: Set<String> = ["Alert: Direct", "Clients", "Global", "Vulnerability", "Test"]
    var body: some View {
        NavigationView {
            List {
                ForEach(listOfSubscriptions, id: \.self) { topic in
                    let subscription = subscriptions[topic] ?? Subscription(isSubscribed: false, isHighPriority: defaultAlertTopics.contains(topic))
                    HStack {
                        Button(action: {
                            toggleSubscription(topic)
                        }) {
                            HStack {
                                Image(systemName: subscription.isSubscribed ? "checkmark.square.fill" : "square")
                                    .foregroundColor(subscription.isSubscribed ? .blue : .gray)
                                Text(topic)
                                    .foregroundColor(subscription.isSubscribed ? .primary : .gray)
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                        Spacer()
                        if subscription.isSubscribed {
                            Toggle(isOn: Binding(
                                get: { subscriptions[topic]?.isHighPriority ?? defaultAlertTopics.contains(topic) },
                                set: { newValue in
                                    if var existingSubscription = subscriptions[topic] {
                                        existingSubscription.isHighPriority = newValue
                                        subscriptions[topic] = existingSubscription
                                    } else {
                                        subscriptions[topic] = Subscription(isSubscribed: true, isHighPriority: newValue)
                                    }
                                    updateSubscriptionPriority(topic: topic, isHighPriority: newValue)
                                }
                            )) {
                                EmptyView()
                            }
                            .toggleStyle(IconToggleStyle())
                        }
                    }
                    .listRowBackground(subscription.isSubscribed ? Color.clear : Color.gray.opacity(0.2))
                }
            }
            .navigationTitle("Subscriptions")
            .onAppear {
                Task {
                    await authenticateAndLoadSubscriptions()
                    await syncSubscriptionsWithServer()
                }
            }
            .alert(item: $errorMessage) { error in
                Alert(title: Text("Error"), message: Text(error.message), dismissButton: .default(Text("OK")))
            }
        }
    }

    private func authenticateAndLoadSubscriptions() async {
        do {
            if UserDefaults.standard.string(forKey: "jwtToken") == nil {
                jwtToken = try await APIClient.shared.authenticateDevice()
                UserDefaults.standard.set(jwtToken, forKey: "jwtToken")
            } else {
                jwtToken = UserDefaults.standard.string(forKey: "jwtToken")
            }
            subscriptions = loadSubscriptions()
            if isFirstLaunch {
                isFirstLaunch = false
                await autoSubscribeToDefaultTopics()
            }
        } catch {
            errorMessage = ErrorWrapper(message: "Failed to authenticate: \(error.localizedDescription)")
        }
    }

    private func autoSubscribeToDefaultTopics() async {
        for topic in defaultAutoSubscriptions {
            guard subscriptions[topic]?.isSubscribed == false else { continue }
            do {
                let isHighPriority = defaultAlertTopics.contains(topic)
                try await performAPIRequest { try await subscribeToTopic(topic, priority: isHighPriority, token: $0) }
                subscriptions[topic] = Subscription(isSubscribed: true, isHighPriority: isHighPriority)
            } catch {
                errorMessage = ErrorWrapper(message: "Failed to auto-subscribe to \(topic): \(error.localizedDescription)")
            }
        }
        saveSubscriptions()
    }

    private func toggleSubscription(_ topic: String) {
        guard jwtToken != nil else {
            errorMessage = ErrorWrapper(message: "Not authenticated. Please try again.")
            return
        }
        Task {
            do {
                let currentSubscription = subscriptions[topic]
                let isFirstTimeEnable = currentSubscription == nil

                if let subscription = currentSubscription, subscription.isSubscribed {
                    // Unsubscribing
                    try await performAPIRequest { try await unsubscribeFromTopic(topic, token: $0) }
                    subscriptions[topic] = Subscription(isSubscribed: false, isHighPriority: false) // Ensure proper reset
                } else {
                    // Subscribing or re-subscribing
                    let isHighPriority = isFirstTimeEnable ? defaultAlertTopics.contains(topic) : (currentSubscription?.isHighPriority ?? false)

                    try await performAPIRequest { try await subscribeToTopic(topic, priority: isHighPriority, token: $0) }
                    subscriptions[topic] = Subscription(isSubscribed: true, isHighPriority: isHighPriority)
                }
                saveSubscriptions()
            } catch {
                errorMessage = ErrorWrapper(message: "Failed to update subscription for \(topic): \(error.localizedDescription)")
            }
        }
    }

    private func updateSubscriptionPriority(topic: String, isHighPriority: Bool) {
        Task {
            do {
                try await performAPIRequest { token in
                    try await subscribeToTopic(topic, priority: isHighPriority, token: token)
                }
                saveSubscriptions()
            } catch {
                errorMessage = ErrorWrapper(message: "Failed to update priority for \(topic): \(error.localizedDescription)")
            }
        }
    }

    private func performAPIRequest(apiCall: (String) async throws -> Void) async throws {
        do {
            guard let token = UserDefaults.standard.string(forKey: "jwtToken") else {
                throw URLError(.userAuthenticationRequired)
            }
            try await apiCall(token)
        } catch {
            if let urlError = error as? URLError, urlError.code == .userAuthenticationRequired {
                let newToken = try await APIClient.shared.authenticateDevice()
                UserDefaults.standard.set(newToken, forKey: "jwtToken")
                try await apiCall(newToken)
            } else {
                throw error
            }
        }
    }

    private func subscribeToTopic(_ topic: String, priority: Bool, token: String) async throws {
        let url = URL(string: "https://api.arguspulse.com/subscribe")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload = [
            "topic": topic,
            "priority": priority ? "high" : "low",
        ]
        request.httpBody = try JSONEncoder().encode(payload)
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

    func loadSubscriptions() -> [String: Subscription] {
        let defaults = UserDefaults.standard
        if let savedData = defaults.data(forKey: "subscriptions"),
           let decodedSubscriptions = try? JSONDecoder().decode([String: Subscription].self, from: savedData)
        {
            return decodedSubscriptions
        } else {
            // If no saved data, initialize with default values
            var defaultSubscriptions: [String: Subscription] = [:]
            for topic in listOfSubscriptions {
                let isHighPriority = defaultAlertTopics.contains(topic)
                defaultSubscriptions[topic] = Subscription(isSubscribed: false, isHighPriority: isHighPriority)
            }
            return defaultSubscriptions
        }
    }

    private func saveSubscriptions() {
        let defaults = UserDefaults.standard
        if let encodedData = try? JSONEncoder().encode(subscriptions) {
            defaults.set(encodedData, forKey: "subscriptions")
        }
    }

    private func syncSubscriptionsWithServer() async {
        do {
            // First, get current server subscriptions
            let serverSubscriptions = try await fetchServerSubscriptions()

            if serverSubscriptions.isEmpty {
                // If server has no subscriptions, push defaults
                await pushDefaultSubscriptionsToServer()
            } else {
                // Update local subscriptions to match server
                updateLocalSubscriptions(from: serverSubscriptions)
            }

            // Save the synchronized subscriptions
            saveSubscriptions()

        } catch {
            errorMessage = ErrorWrapper(message: "Failed to sync subscriptions: \(error.localizedDescription)")
        }
    }

    private func fetchServerSubscriptions() async throws -> [(topic: String, priority: String)] {
        let url = URL(string: "https://api.arguspulse.com/subscriptions")!
        let data = try await APIClient.shared.performAuthenticatedRequest(to: url, body: Empty?.none)
        let response = try JSONDecoder().decode(SubscriptionsResponse.self, from: data)
        return response.subscriptions.map { ($0.topic, $0.priority) }
    }

    private func pushDefaultSubscriptionsToServer() async {
        for topic in defaultAutoSubscriptions {
            do {
                let isHighPriority = defaultAlertTopics.contains(topic)
                try await performAPIRequest { try await subscribeToTopic(topic, priority: isHighPriority, token: $0) }
                subscriptions[topic] = Subscription(isSubscribed: true, isHighPriority: isHighPriority)
            } catch {
                errorMessage = ErrorWrapper(message: "Failed to push default subscription for \(topic): \(error.localizedDescription)")
            }
        }
    }

    private func updateLocalSubscriptions(from serverSubscriptions: [(topic: String, priority: String)]) {
        // Reset all subscriptions to unsubscribed
        for topic in listOfSubscriptions {
            subscriptions[topic] = Subscription(isSubscribed: false, isHighPriority: false)
        }

        // Update based on server data
        for (topic, priority) in serverSubscriptions {
            subscriptions[topic] = Subscription(
                isSubscribed: true,
                isHighPriority: priority == "high"
            )
        }
    }
}

struct IconToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 15)
                    .fill(configuration.isOn ? Color.green : Color.gray)
                    .frame(width: 50, height: 30)
                HStack {
                    if configuration.isOn {
                        Image(systemName: "bell.fill")
                            .foregroundColor(.white)
                            .padding(.leading, 5)
                    } else {
                        Image(systemName: "bell.slash.fill")
                            .foregroundColor(.white)
                            .padding(.trailing, 5)
                    }
                }
                .frame(width: 50, alignment: configuration.isOn ? .leading : .trailing)
            }
            .onTapGesture {
                withAnimation {
                    configuration.isOn.toggle()
                }
            }
        }
    }
}
