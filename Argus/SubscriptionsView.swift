import SwiftUI

struct Subscription: Codable {
    var isSubscribed: Bool
    var isHighPriority: Bool
}

struct ErrorWrapper: Identifiable {
    let id = UUID()
    let message: String
}

struct SubscriptionsView: View {
    @State private var subscriptions: [String: Subscription] = [:]
    @State private var jwtToken: String? = nil
    @State private var errorMessage: ErrorWrapper? = nil
    @State private var isFirstLaunch: Bool = true
    let listOfSubscriptions: [String] = ["Alert: Direct", "Alert: Near", "Apple", "Bitcoins", "Clients", "Drupal", "E-Ink", "EVs", "Global", "LLMs", "Longevity", "Music", "Rust", "Space", "Tuscany", "Vulnerability", "Test"]
    let defaultAutoSubscriptions: [String] = ["Apple", "Bitcoins", "Drupal", "EVs", "Global", "LLMs", "Space", "Vulnerability"]
    private let defaultAlertTopics: Set<String> = ["Alert: Direct", "Clients", "Global", "Vulnerability", "Test"]
    var body: some View {
        NavigationView {
            List {
                ForEach(listOfSubscriptions, id: \.self) { topic in
                    let subscription = subscriptions[topic] ?? Subscription(isSubscribed: false, isHighPriority: true)
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
                                get: { subscription.isHighPriority },
                                set: { newValue in
                                    subscriptions[topic]?.isHighPriority = newValue
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
                guard subscriptions[topic]?.isSubscribed == false else { continue }
                do {
                    try await performAPIRequest { try await subscribeToTopic(topic, priority: true, token: $0) }
                    subscriptions[topic] = Subscription(isSubscribed: true, isHighPriority: true)
                } catch {
                    errorMessage = ErrorWrapper(message: "Failed to auto-subscribe to \(topic): \(error.localizedDescription)")
                }
            }
            saveSubscriptions()
        }
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
                    subscriptions[topic] = Subscription(isSubscribed: false, isHighPriority: subscription.isHighPriority)
                } else {
                    // Subscribing or re-subscribing
                    let isHighPriority: Bool
                    if isFirstTimeEnable {
                        // First time enabling: use default alert setting
                        isHighPriority = defaultAlertTopics.contains(topic)
                    } else {
                        // Re-enabling: use previous alert setting
                        isHighPriority = currentSubscription?.isHighPriority ?? false
                    }
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
                defaultSubscriptions[topic] = Subscription(isSubscribed: false, isHighPriority: true)
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
}

struct IconToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 15)
                    .fill(configuration.isOn ? Color.green : Color.red)
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
