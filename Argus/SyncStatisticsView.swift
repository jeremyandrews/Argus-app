import SwiftUI

struct SyncStatisticsView: View {
    @Environment(TabNavigationState.self) private var tabNavigation
    @Environment(\.dismiss) private var dismiss
    @StateObject private var coordinator = AutoSyncCoordinator.shared
    @State private var performanceReport: String = ""
    @State private var isLoading = true
    @State private var showingClearAlert = false
    @State private var isAtTop: Bool = true
    @State private var scrollPosition = ScrollPosition()
    
    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ProgressView("Loading sync statistics...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        // Current Status Section
                        currentStatusSection
                            .id("syncStatsListTop")
                    
                        Divider()
                    
                        // Performance Metrics Section
                        performanceMetricsSection
                    
                        Divider()
                    
                        // System Resources Section
                        systemResourcesSection
                    
                        Divider()
                    
                        // Actions Section
                        actionsSection
                    }
                    .padding()
                }
                .scrollPosition($scrollPosition)
                .background(
                    // Scroll position detection using geometry reader
                    GeometryReader { geometry in
                        Color.clear
                            .onChange(of: geometry.frame(in: .global).minY) { _, newY in
                                // Detect if we're at the top of the scroll view
                                let newIsAtTop = newY >= -10 // Allow small tolerance for "at top"
                                if newIsAtTop != isAtTop {
                                    isAtTop = newIsAtTop
                                    tabNavigation.updateScrollPosition(for: 2, isAtTop: newIsAtTop, scrollOffset: newY)
                                }
                            }
                    }
                )
                .onReceive(NotificationCenter.default.publisher(for: .tabScrollToTop)) { notification in
                    if let tabIndex = notification.object as? Int, tabIndex == 2 {
                        withAnimation(.easeInOut(duration: 0.5)) {
                            scrollPosition.scrollTo(edge: .top)
                        }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .tabNavigateUp)) { notification in
                    print("SyncStatisticsView: Received tabNavigateUp notification")
                    if let tabIndex = notification.object as? Int {
                        print("SyncStatisticsView: tabNavigateUp notification for tab \(tabIndex)")
                        if tabIndex == 2 {
                            print("SyncStatisticsView: Tab matches (2), calling dismiss()")
                            dismiss()
                        } else {
                            print("SyncStatisticsView: Tab doesn't match (expected 2, got \(tabIndex))")
                        }
                    } else {
                        print("SyncStatisticsView: tabNavigateUp notification has no tabIndex")
                    }
                }
            }
        }
        .onAppear {
            // Set navigation state to indicate we're in a subview
            tabNavigation.setNavigationState(for: 2, inSubview: true, level: 1)
            // Reset scroll state for progressive navigation to work properly
            tabNavigation.resetScrollState(for: 2)
            // Initialize scroll position for this subview
            isAtTop = true
            tabNavigation.updateScrollPosition(for: 2, isAtTop: true)
            Task {
                await refreshData()
            }
        }
        .onDisappear {
            // Clear navigation state when leaving the view
            tabNavigation.setNavigationState(for: 2, inSubview: false, level: 0)
        }
        .navigationTitle("Sync Statistics")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    Task {
                        await refreshData()
                    }
                }) {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .alert("Clear Performance History", isPresented: $showingClearAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Clear", role: .destructive) {
                Task {
                    await clearPerformanceHistory()
                }
            }
        } message: {
            Text("This will permanently delete all stored performance monitoring data. This action cannot be undone.")
        }
    }
    
    // MARK: - Current Status Section
    
    private var currentStatusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Current Status", systemImage: "circle.fill")
                .font(.headline)
                .foregroundColor(.blue)
            
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Sync State:")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(coordinator.isAutoSyncing ? "Active" : "Idle")
                        .font(.subheadline)
                        .foregroundColor(coordinator.isAutoSyncing ? .green : .orange)
                }
                
                HStack {
                    Text("Background Sync:")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(coordinator.autoSyncEnabled ? "Enabled" : "Disabled")
                        .font(.subheadline)
                        .foregroundColor(coordinator.autoSyncEnabled ? .green : .red)
                }
                
                HStack {
                    Text("Network Connection:")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(networkStatusText)
                        .font(.subheadline)
                        .foregroundColor(networkStatusColor)
                }
            }
            .padding()
            .background(Color(UIColor.systemGray6))
            .cornerRadius(8)
        }
    }
    
    // MARK: - Performance Metrics Section
    
    private var performanceMetricsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Performance History", systemImage: "chart.line.uptrend.xyaxis")
                .font(.headline)
                .foregroundColor(.green)
            
            if coordinator.performanceMetrics.isEmpty {
                Text("No performance data available yet. Performance metrics will appear after sync operations.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding()
                    .background(Color(UIColor.systemGray6))
                    .cornerRadius(8)
            } else {
                // Recent Metrics Table
                VStack(alignment: .leading, spacing: 0) {
                    // Table Header
                    HStack(spacing: 0) {
                        Text("Time")
                            .font(.caption)
                            .bold()
                            .foregroundColor(.secondary)
                            .frame(width: 60, alignment: .leading)
                        
                        Text("Duration")
                            .font(.caption)
                            .bold()
                            .foregroundColor(.secondary)
                            .frame(width: 80, alignment: .center)
                        
                        Text("Articles")
                            .font(.caption)
                            .bold()
                            .foregroundColor(.secondary)
                            .frame(width: 70, alignment: .center)
                        
                        Text("Score")
                            .font(.caption)
                            .bold()
                            .foregroundColor(.secondary)
                            .frame(width: 60, alignment: .center)
                        
                        Text("Network")
                            .font(.caption)
                            .bold()
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(UIColor.systemGray5))
                    
                    // Recent performance data (last 10 entries)
                    ForEach(coordinator.performanceMetrics.suffix(10).reversed(), id: \.timestamp) { metric in
                        HStack(spacing: 0) {
                            Text(formatTime(metric.timestamp))
                                .font(.system(.caption, design: .monospaced))
                                .frame(width: 60, alignment: .leading)
                            
                            Text(formatDuration(metric.duration))
                                .font(.system(.caption, design: .monospaced))
                                .frame(width: 80, alignment: .center)
                            
                            Text("\(metric.articlesProcessed)")
                                .font(.system(.caption, design: .monospaced))
                                .frame(width: 70, alignment: .center)
                            
                            Text("\(Int(metric.performanceScore))")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(scoreColor(metric.performanceScore))
                                .frame(width: 60, alignment: .center)
                            
                            Text(formatThroughput(metric.throughputKbps ?? 0))
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        
                        if metric.timestamp != coordinator.performanceMetrics.suffix(10).reversed().last?.timestamp {
                            Divider()
                                .padding(.leading, 12)
                        }
                    }
                }
                .background(Color(UIColor.systemGray6))
                .cornerRadius(8)
                
                // Summary Statistics
                summaryStatistics
            }
        }
    }
    
    // MARK: - System Resources Section
    
    private var systemResourcesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("System Resources", systemImage: "cpu")
                .font(.headline)
                .foregroundColor(.orange)
            
            if coordinator.resourceSnapshots.isEmpty {
                Text("No system resource data available yet.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding()
                    .background(Color(UIColor.systemGray6))
                    .cornerRadius(8)
            } else if let latestSnapshot = coordinator.resourceSnapshots.last {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Memory Usage:")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(formatMemory(latestSnapshot.memoryUsageBytes))
                            .font(.subheadline)
                            .foregroundColor(.primary)
                    }
                    
                    HStack {
                        Text("Memory Pressure:")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(latestSnapshot.memoryPressure.rawValue)
                            .font(.subheadline)
                            .foregroundColor(memoryPressureColor(latestSnapshot.memoryPressure))
                    }
                    
                    #if os(iOS)
                    if let batteryLevel = latestSnapshot.batteryLevel {
                        HStack {
                            Text("Battery Level:")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(Int(batteryLevel * 100))%")
                                .font(.subheadline)
                                .foregroundColor(batteryColor(batteryLevel))
                        }
                    }
                    
                    HStack {
                        Text("Thermal State:")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(latestSnapshot.thermalState.rawValue)")
                            .font(.subheadline)
                            .foregroundColor(thermalStateColor(latestSnapshot.thermalState))
                    }
                    #endif
                }
                .padding()
                .background(Color(UIColor.systemGray6))
                .cornerRadius(8)
            }
        }
    }
    
    // MARK: - Actions Section
    
    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Actions", systemImage: "wrench.and.screwdriver")
                .font(.headline)
                .foregroundColor(.red)
            
            VStack(spacing: 8) {
                Button(action: {
                    showingClearAlert = true
                }) {
                    HStack {
                        Image(systemName: "trash")
                        Text("Clear Performance History")
                    }
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(UIColor.systemGray6))
                    .cornerRadius(8)
                }
                
                Text("Performance history includes \(coordinator.performanceMetrics.count) sync operations and \(coordinator.resourceSnapshots.count) resource snapshots.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    // MARK: - Summary Statistics
    
    private var summaryStatistics: some View {
        let metrics = coordinator.performanceMetrics
        let avgDuration = metrics.isEmpty ? 0 : metrics.map { $0.duration }.reduce(0, +) / Double(metrics.count)
        let avgScore = metrics.isEmpty ? 0 : metrics.map { $0.performanceScore }.reduce(0, +) / Double(metrics.count)
        let successfulSyncs = metrics.filter { $0.success }.count
        let successRate = metrics.isEmpty ? 0 : Double(successfulSyncs) / Double(metrics.count) * 100
        
        return VStack(alignment: .leading, spacing: 8) {
            Text("Summary Statistics")
                .font(.subheadline)
                .bold()
            
            HStack {
                VStack(alignment: .leading) {
                    Text("Avg Duration")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(formatDuration(avgDuration))
                        .font(.caption)
                        .bold()
                }
                
                Spacer()
                
                VStack(alignment: .center) {
                    Text("Success Rate")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(Int(successRate))%")
                        .font(.caption)
                        .bold()
                        .foregroundColor(successRate >= 90 ? .green : successRate >= 70 ? .orange : .red)
                }
                
                Spacer()
                
                VStack(alignment: .trailing) {
                    Text("Avg Score")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(Int(avgScore))")
                        .font(.caption)
                        .bold()
                        .foregroundColor(scoreColor(avgScore))
                }
            }
        }
        .padding()
        .background(Color(UIColor.systemGray5))
        .cornerRadius(8)
    }
    
    // MARK: - Helper Methods
    
    private func refreshData() async {
        isLoading = true
        
        performanceReport = coordinator.getPerformanceReport()
        
        await MainActor.run {
            isLoading = false
        }
    }
    
    private func clearPerformanceHistory() async {
        coordinator.clearPerformanceHistory()
        await refreshData()
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 1 {
            return String(format: "%.1fs", duration)
        } else if duration < 60 {
            return String(format: "%.0fs", duration)
        } else {
            let minutes = Int(duration / 60)
            let seconds = Int(duration.truncatingRemainder(dividingBy: 60))
            return String(format: "%d:%02ds", minutes, seconds)
        }
    }
    
    private func formatThroughput(_ kbps: Double) -> String {
        if kbps < 1024 {
            return String(format: "%.0f KB/s", kbps)
        } else {
            return String(format: "%.1f MB/s", kbps / 1024)
        }
    }
    
    private func formatMemory(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        return String(format: "%.1f MB", mb)
    }
    
    private func scoreColor(_ score: Double) -> Color {
        if score >= 80 { return .green }
        else if score >= 60 { return .orange }
        else { return .red }
    }
    
    private func memoryPressureColor(_ pressure: AutoSyncCoordinator.SystemResourceSnapshot.MemoryPressure) -> Color {
        switch pressure {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }
    
    #if os(iOS)
    private func batteryColor(_ level: Float) -> Color {
        if level >= 0.5 { return .green }
        else if level >= 0.2 { return .orange }
        else { return .red }
    }
    
    private func thermalStateColor(_ state: ProcessInfo.ThermalState) -> Color {
        switch state {
        case .nominal: return .green
        case .fair: return .orange
        case .serious, .critical: return .red
        @unknown default: return .gray
        }
    }
    #endif
    
    private var networkStatusText: String {
        // This is a simplified network status - in a real implementation,
        // you might want to access network monitoring data from AutoSyncCoordinator
        return "Connected"
    }
    
    private var networkStatusColor: Color {
        return .green
    }

}

#Preview {
    NavigationView {
        SyncStatisticsView()
    }
}
