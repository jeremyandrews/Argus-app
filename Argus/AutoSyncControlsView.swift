import SwiftUI

/// iOS18+ Streamlined Auto-Sync controls for main SettingsView
/// Improved design with better visual hierarchy and consistent styling
struct AutoSyncControlsView: View {
    @ObservedObject private var coordinator = AutoSyncCoordinator.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Auto-Sync Toggle with improved styling
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Enable Auto-Sync", isOn: $coordinator.autoSyncEnabled)
                
                if !coordinator.autoSyncEnabled {
                    Text("Articles will only sync when you manually refresh or open the app.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            
            if coordinator.autoSyncEnabled {
                // Sync Frequency Picker - no duplicate header
                Picker("Sync Frequency", selection: Binding(
                    get: { coordinator.syncFrequencyMinutes },
                    set: { coordinator.updateSyncFrequency($0) }
                )) {
                    Text("Every 5 minutes").tag(5)
                    Text("Every 10 minutes").tag(10)
                    Text("Every 15 minutes").tag(15)
                    Text("Every 30 minutes").tag(30)
                }
                .pickerStyle(.menu)
                
                // Status and Last Sync Information
                VStack(alignment: .leading, spacing: 8) {
                    if coordinator.isAutoSyncing {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Syncing...")
                                .font(.footnote)
                                .foregroundColor(.blue)
                        }
                    } else if let lastSync = coordinator.lastAutoSyncTime {
                        Text("Last sync: \(lastSync.formatted(.relative(presentation: .named)))")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Auto-sync has not run yet")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    
                    // Manual Sync Button - Standard styling to avoid clash
                    Button(action: {
                        Task {
                            await coordinator.performManualSync()
                        }
                    }) {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                                .font(.footnote)
                            Text("Sync Now")
                                .font(.subheadline)
                                .fontWeight(.medium)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(.systemGray6))
                        .foregroundColor(.primary)
                        .cornerRadius(10)
                    }
                    .disabled(coordinator.isAutoSyncing)
                    .opacity(coordinator.isAutoSyncing ? 0.6 : 1.0)
                }
            }
        }
    }
}

// MARK: - Preview

struct AutoSyncControlsView_Previews: PreviewProvider {
    static var previews: some View {
        Form {
            Section("Auto-Sync") {
                AutoSyncControlsView()
            }
        }
    }
}
