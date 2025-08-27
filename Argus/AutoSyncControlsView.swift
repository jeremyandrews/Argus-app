import SwiftUI

/// Phase 3.1: Streamlined Auto-Sync controls for main SettingsView
/// Implements the exact interface specification from the implementation plan
struct AutoSyncControlsView: View {
    @ObservedObject private var coordinator = AutoSyncCoordinator.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Phase 3.1: Enable Auto-Sync Toggle
            Toggle("Enable Auto-Sync", isOn: $coordinator.autoSyncEnabled)
            
            if coordinator.autoSyncEnabled {
                // Phase 3.1: Sync Frequency Picker
                VStack(alignment: .leading, spacing: 8) {
                    Text("Sync Frequency")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    Picker("Sync Frequency", selection: Binding(
                        get: { coordinator.syncFrequencyMinutes },
                        set: { coordinator.updateSyncFrequency($0) }
                    )) {
                        Text("5 min").tag(5)
                        Text("10 min").tag(10)
                        Text("15 min").tag(15)
                        Text("30 min").tag(30)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                }
                
                // Phase 3.1: Last sync time display
                if let lastSync = coordinator.lastAutoSyncTime {
                    Text("Last sync: \(lastSync.formatted(.relative(presentation: .named)))")
                        .foregroundColor(.secondary)
                        .font(.footnote)
                }
                
                // Phase 3.1: Sync Now button
                HStack {
                    Spacer()
                    
                    Button("Sync Now") {
                        Task {
                            await coordinator.performManualSync()
                        }
                    }
                    .disabled(coordinator.isAutoSyncing)
                    .buttonStyle(.borderedProminent)
                    
                    Spacer()
                }
                .padding(.top, 8)
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
