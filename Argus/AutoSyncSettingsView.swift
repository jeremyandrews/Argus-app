import SwiftUI

/// Auto-sync settings view component for Phase 1 implementation
struct AutoSyncSettingsView: View {
    @ObservedObject private var autoSync = AutoSyncCoordinator.shared
    @AppStorage("autoSyncOnCellular") private var autoSyncOnCellular: Bool = UserDefaults.standard.allowCellularSync
    
    // Frequency options in minutes
    private let frequencyOptions = [5, 10, 15, 30]
    
    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 15) {
                // Auto-sync toggle
                VStack(alignment: .leading) {
                    Toggle("Enable Auto-Sync", isOn: Binding(
                        get: { autoSync.autoSyncEnabled },
                        set: { autoSync.setAutoSyncEnabled($0) }
                    ))
                    
                    Text("Automatically sync articles every few minutes when the app is active and when returning from background.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .padding(.top, 2)
                }
                
                if autoSync.autoSyncEnabled {
                    Divider()
                    
                    // Sync frequency picker
                    VStack(alignment: .leading) {
                        Text("Sync Frequency")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        Picker("Sync Frequency", selection: Binding(
                            get: { UserDefaults.standard.autoSyncFrequencyMinutes },
                            set: { autoSync.updateSyncFrequency($0) }
                        )) {
                            ForEach(frequencyOptions, id: \.self) { minutes in
                                Text("\(minutes) minute\(minutes == 1 ? "" : "s")")
                                    .tag(minutes)
                            }
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        
                        Text("How often to check for new articles while the app is active.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .padding(.top, 2)
                    }
                    
                    Divider()
                    
                    // Cellular data toggle for auto-sync
                    VStack(alignment: .leading) {
                        Toggle("Auto-Sync on Cellular", isOn: $autoSyncOnCellular)
                        
                        Text("Allow automatic syncing when using cellular data. Manual syncs will still respect the main cellular sync setting.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .padding(.top, 2)
                    }
                    
                    Divider()
                    
                    // Status information
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "clock")
                                .foregroundColor(.secondary)
                            
                            if let lastSync = autoSync.lastAutoSyncTime {
                                Text("Last auto-sync: \(lastSync, formatter: relativeDateFormatter)")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            } else {
                                Text("No auto-sync performed yet")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        if let nextSync = autoSync.nextScheduledSync {
                            HStack {
                                Image(systemName: "timer")
                                    .foregroundColor(.secondary)
                                
                                Text("Next sync: \(nextSync, formatter: timeFormatter)")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        if autoSync.isAutoSyncing {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .frame(width: 16, height: 16)
                                
                                Text("Auto-syncing...")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    
                    Divider()
                    
                    // Manual sync button
                    HStack {
                        Spacer()
                        
                        Button("Sync Now") {
                            Task {
                                await autoSync.triggerManualSync()
                            }
                        }
                        .disabled(autoSync.isAutoSyncing)
                        .buttonStyle(.borderedProminent)
                        
                        Spacer()
                    }
                    .padding(.vertical, 5)
                }
            }
        } header: {
            Text("Auto-Sync")
        } footer: {
            if autoSync.autoSyncEnabled {
                Text("Auto-sync checks for new articles in the background and when you open the app. It respects your network preferences and won't interrupt reading or other activities.")
            } else {
                Text("Enable auto-sync to automatically receive new articles without having to manually refresh.")
            }
        }
    }
    
    // MARK: - Formatters
    
    private var relativeDateFormatter: RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }
    
    private var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }
}

// MARK: - Preview

struct AutoSyncSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            Form {
                AutoSyncSettingsView()
            }
            .navigationTitle("Auto-Sync Settings")
        }
    }
}
