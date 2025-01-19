import SwiftUI

struct ErrorWrapper: Identifiable {
    let id = UUID()
    let message: String
}

struct SubscriptionInfo: Codable {
    var isSubscribed: Bool
    var isHighPriority: Bool
}

struct SubscriptionsView: View {
    @State private var subscriptions: [String: SubscriptionInfo] = [:]
    @State private var jwtToken: String? = nil
    @State private var errorMessage: ErrorWrapper? = nil
    @AppStorage("isFirstLaunch") private var isFirstLaunch: Bool = true

    let listOfSubscriptions: [String] = ["Alert", "Apple", "Bitcoins", "Clients", "Drupal", "E-Ink", "EVs", "Global", "LLMs", "Longevity", "Music", "Rust", "Space", "Tuscany", "Vulnerability", "Test"]

    let highPriorityDefaults = ["Alert", "Clients", "Global", "Vulnerability", "Test"]
    let lowPriorityDefaults = ["Apple", "Bitcoins", "Drupal", "Rust", "Space"]

    var body: some View {
        NavigationView {
            VStack {
                // Column headers
                HStack {
                    Text("Topic")
                        .font(.headline)
                        .padding(.leading)
                    Spacer()
                    Text("Priority")
                        .font(.headline)
                        .padding(.trailing)
                }
                .padding(.top)

                List {
                    ForEach(listOfSubscriptions, id: \.self) { topic in
                        SubscriptionRow(topic: topic, subscriptionInfo: binding(for: topic))
                    }
                }
            }
            .navigationTitle("Subscriptions")
            .onAppear {
                loadSubscriptionsAndAuthenticate()
            }
            .alert(item: $errorMessage) { error in
                Alert(title: Text("Error"), message: Text(error.message), dismissButton: .default(Text("OK")))
            }
        }
    }

    private func binding(for topic: String) -> Binding<SubscriptionInfo> {
        Binding(
            get: { self.subscriptions[topic] ?? SubscriptionInfo(isSubscribed: false, isHighPriority: false) },
            set: { self.subscriptions[topic] = $0 }
        )
    }

    private func loadSubscriptionsAndAuthenticate() {
        subscriptions = loadSubscriptions()

        if isFirstLaunch {
            applyDefaultSubscriptions()
            isFirstLaunch = false
        }

        authenticateDevice()
    }

    private func authenticateDevice() {
        Task {
            do {
                jwtToken = try await authenticateDevice()
                // Sync subscriptions with the server if needed
                syncSubscriptionsWithServer()
            } catch {
                errorMessage = ErrorWrapper(message: "Failed to authenticate: \(error.localizedDescription)")
            }
        }
    }

    private func applyDefaultSubscriptions() {
        for topic in listOfSubscriptions {
            if highPriorityDefaults.contains(topic) {
                subscriptions[topic] = SubscriptionInfo(isSubscribed: true, isHighPriority: true)
            } else if lowPriorityDefaults.contains(topic) {
                subscriptions[topic] = SubscriptionInfo(isSubscribed: true, isHighPriority: false)
            } else {
                subscriptions[topic] = SubscriptionInfo(isSubscribed: false, isHighPriority: false)
            }
        }
        saveSubscriptions(subscriptions)
    }

    private func syncSubscriptionsWithServer() {
        Task {
            for (topic, info) in subscriptions {
                do {
                    if info.isSubscribed {
                        try await performAPIRequest { try await subscribeToTopic(topic, token: $0) }
                    } else {
                        try await performAPIRequest { try await unsubscribeFromTopic(topic, token: $0) }
                    }
                } catch {
                    errorMessage = ErrorWrapper(message: "Failed to sync \(topic): \(error.localizedDescription)")
                }
            }
        }
    }

    private func toggleSubscription(_ topic: String, info: SubscriptionInfo) {
        guard jwtToken != nil else {
            errorMessage = ErrorWrapper(message: "Not authenticated. Please try again.")
            return
        }
        Task {
            do {
                if info.isSubscribed {
                    try await performAPIRequest { try await unsubscribeFromTopic(topic, token: $0) }
                } else {
                    try await performAPIRequest { try await subscribeToTopic(topic, token: $0) }
                }
                subscriptions[topic] = SubscriptionInfo(isSubscribed: !info.isSubscribed, isHighPriority: info.isHighPriority)
                saveSubscriptions(subscriptions)
            } catch {
                errorMessage = ErrorWrapper(message: "Failed to update subscription for \(topic): \(error.localizedDescription)")
            }
        }
    }

    private func togglePriority(_ topic: String, isHighPriority: Bool) {
        guard var info = subscriptions[topic] else { return }
        info.isHighPriority = isHighPriority
        subscriptions[topic] = info
        saveSubscriptions(subscriptions)
        // You might want to add an API call here to update the priority on the server
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

    func loadSubscriptions() -> [String: SubscriptionInfo] {
        let defaults = UserDefaults.standard
        if let savedData = defaults.data(forKey: "subscriptions"),
           let decodedSubscriptions = try? JSONDecoder().decode([String: SubscriptionInfo].self, from: savedData)
        {
            return decodedSubscriptions
        }

        // If no saved data, return an empty dictionary
        return [:]
    }

    private func saveSubscriptions(_ subscriptions: [String: SubscriptionInfo]) {
        let defaults = UserDefaults.standard
        if let encoded = try? JSONEncoder().encode(subscriptions) {
            defaults.set(encoded, forKey: "subscriptions")
        }
    }
}

struct SubscriptionRow: View {
    let topic: String
    @Binding var subscriptionInfo: SubscriptionInfo

    var body: some View {
        HStack {
            // Topic column
            HStack {
                Image(systemName: subscriptionInfo.isSubscribed ? "checkmark.square.fill" : "square")
                    .foregroundColor(subscriptionInfo.isSubscribed ? .blue : .gray)
                    .onTapGesture {
                        subscriptionInfo.isSubscribed.toggle()
                    }

                Text(topic)
                    .foregroundColor(subscriptionInfo.isSubscribed ? .primary : .gray)
            }

            Spacer()

            // Priority column
            if subscriptionInfo.isSubscribed {
                HStack {
                    Image(systemName: "bell.fill")
                        .foregroundColor(subscriptionInfo.isHighPriority ? .gray : .blue)

                    Toggle("", isOn: $subscriptionInfo.isHighPriority)
                        .labelsHidden()
                        .toggleStyle(SwitchToggleStyle(tint: .blue))

                    Image(systemName: "bell.and.waves.left.and.right.fill")
                        .foregroundColor(subscriptionInfo.isHighPriority ? .blue : .gray)
                }
                .padding(6)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
            } else {
                // Placeholder to maintain alignment when not subscribed
                Color.clear
                    .frame(width: 120, height: 30)
            }
        }
    }
}
