import SwiftUI

struct SyncStatisticsView: View {
    @Environment(TabNavigationState.self) private var tabNavigation
    @Environment(\.dismiss) private var dismiss
    @StateObject private var coordinator = AutoSyncCoordinator.shared
    @State private var isAtTop: Bool = true
    @State private var scrollPosition = ScrollPosition()
    
    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SYNC STATISTICS")
                        .font(.largeTitle.bold())
                        .foregroundColor(.primary)
                }
                
                Spacer()
                
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal)
            
            // Current Status
            VStack(alignment: .leading, spacing: 16) {
                Text("Current Status")
                    .font(.headline)
                
                VStack(spacing: 12) {
                    HStack {
                        Text("Auto-Sync")
                        Spacer()
                        Text(coordinator.autoSyncEnabled ? "Enabled" : "Disabled")
                            .foregroundColor(coordinator.autoSyncEnabled ? .green : .red)
                    }
                    
                    HStack {
                        Text("Sync State")
                        Spacer()
                        Text(coordinator.isAutoSyncing ? "Active" : "Idle")
                            .foregroundColor(coordinator.isAutoSyncing ? .blue : .gray)
                    }
                    
                    HStack {
                        Text("Frequency")
                        Spacer()
                        Text("\(coordinator.syncFrequencyMinutes) minutes")
                            .foregroundColor(.secondary)
                    }
                    
                    if let lastSync = coordinator.lastAutoSyncTime {
                        HStack {
                            Text("Last Sync")
                            Spacer()
                            Text(formatLastSyncTime(lastSync))
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    if let nextSync = coordinator.nextScheduledSync {
                        HStack {
                            Text("Next Sync")
                            Spacer()
                            Text(formatNextSyncTime(nextSync))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .padding()
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(10)
            .padding(.horizontal)
            
            // Battery Optimization Info
            VStack(alignment: .leading, spacing: 16) {
                Text("Battery Optimizations")
                    .font(.headline)
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("• Minimum 30-minute sync intervals")
                    Text("• Respects Low Power Mode")
                    Text("• Defers sync when battery < 15%")
                    Text("• Conservative background sync")
                    Text("• Performance monitoring disabled")
                }
                .font(.subheadline)
                .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(10)
            .padding(.horizontal)
            
            Spacer()
        }
        .navigationBarHidden(true)
        .onAppear {
            tabNavigation.setNavigationState(for: 2, inSubview: true, level: 1)
            tabNavigation.resetScrollState(for: 2)
            isAtTop = true
            tabNavigation.updateScrollPosition(for: 2, isAtTop: true)
        }
        .onDisappear {
            tabNavigation.setNavigationState(for: 2, inSubview: false, level: 0)
        }
        .onReceive(NotificationCenter.default.publisher(for: .tabScrollToTop)) { notification in
            if let tabIndex = notification.object as? Int, tabIndex == 2 {
                withAnimation(.easeInOut(duration: 0.5)) {
                    scrollPosition.scrollTo(edge: .top)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tabNavigateUp)) { notification in
            if let tabIndex = notification.object as? Int, tabIndex == 2 {
                dismiss()
            }
        }
    }
    
    private func formatLastSyncTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
    
    private func formatNextSyncTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

#Preview {
    NavigationView {
        SyncStatisticsView()
    }
}
