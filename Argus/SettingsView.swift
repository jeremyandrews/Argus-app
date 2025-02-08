import SwiftUI

struct SettingsView: View {
    @AppStorage("autoDeleteDays") private var autoDeleteDays: Int = UserDefaults.standard.object(forKey: "autoDeleteDays") == nil ? 3 : UserDefaults.standard.integer(forKey: "autoDeleteDays")

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Auto-delete Articles")) {
                    Text("Automatically delete articles older than the selected number of days. (Bookmarked or Archived articles will not be automatically deleted.)")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 5)

                    VStack(alignment: .leading) {
                        Text(autoDeleteDays == 0 ? "Disabled" : "After \(autoDeleteDays) day\(autoDeleteDays == 1 ? "" : "s")")
                            .font(.headline)
                            .padding(.bottom, 5)

                        VStack(spacing: 4) {
                            Slider(value: Binding(
                                get: { Double(autoDeleteDays) },
                                set: { autoDeleteDays = Int($0) }
                            ), in: 0 ... 7, step: 1)

                            HStack {
                                ForEach(0 ... 7, id: \.self) { mark in
                                    Text("\(mark)")
                                        .font(.caption2)
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            .padding(.horizontal, 4)
                        }
                    }
                }

                Section(header: Text("About Argus")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Argus is an artificial intelligence (AI) agent designed to monitor and analyze numerous information sources. As an \"AI agent\", Argus performs tasks autonomously, making decisions based on the data it receives.")
                            .font(.footnote)
                            .foregroundColor(.secondary)

                        Text("The name \"Argus\" is inspired by Argus Panoptes, the all-seeing giant in Greek mythology, reflecting the program's ability to monitor and analyze numerous information sources.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 5)
                }
            }
            .navigationTitle("Settings")
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
