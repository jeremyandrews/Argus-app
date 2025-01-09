import SwiftUI

struct SubscriptionsView: View {
    @State private var subscriptions: [String: Bool] = [:]
    let listOfSubscriptions: [String] = ["Alert", "Apple", "Bitcoins", "Clients", "Drupal", "E-Ink", "EVs", "Global", "LLMs", "Longevity", "Music", "Rust", "Space", "Tuscany", "Vulnerability", "Test"]

    var body: some View {
        NavigationView {
            List {
                ForEach(listOfSubscriptions, id: \.self) { subscription in
                    let isSelected = subscriptions[subscription] ?? false
                    Button(action: {
                        subscriptions[subscription] = !isSelected
                        saveSubscriptions(subscriptions)
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
                subscriptions = loadSubscriptions()
            }
        }
    }

    private func loadSubscriptions() -> [String: Bool] {
        // Load subscriptions from UserDefaults
        let defaults = UserDefaults.standard
        let subscriptionString = defaults.string(forKey: "subscriptions") ?? ""
        var subscriptions: [String: Bool] = [:]

        // Parse subscriptions string
        if !subscriptionString.isEmpty {
            let components = subscriptionString.components(separatedBy: ",")
            for component in components {
                let parts = component.components(separatedBy: ":")
                if parts.count == 2 {
                    subscriptions[parts[0]] = parts[1] == "true"
                }
            }
        } else {
            // Default subscriptions
            for topic in listOfSubscriptions {
                switch topic {
                case "Apple", "Bitcoins", "Drupal", "LLMs", "Space":
                    subscriptions[topic] = true
                default:
                    subscriptions[topic] = false
                }
            }
        }

        return subscriptions
    }

    private func saveSubscriptions(_ subscriptions: [String: Bool]) {
        // Save subscriptions to UserDefaults
        let defaults = UserDefaults.standard
        var subscriptionString = ""

        // Build subscriptions string
        for (topic, isEnabled) in subscriptions {
            if !subscriptionString.isEmpty {
                subscriptionString += ","
            }
            subscriptionString += "\(topic):\(isEnabled)"
        }

        defaults.set(subscriptionString, forKey: "subscriptions")
    }
}
