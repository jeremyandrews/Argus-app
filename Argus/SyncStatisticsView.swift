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
    
    // Cyberpunk animation states
    @State private var gridOffset: CGFloat = 0
    @State private var pulseIntensity: Double = 0
    @State private var dataStreamOffset: CGFloat = 0
    
    var body: some View {
        ZStack {
            // Cyberpunk background
            CyberpunkBackgroundView(gridOffset: $gridOffset)
            
            VStack(spacing: 0) {
                if isLoading {
                    CyberpunkLoadingView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            // Header
                            cyberpunkHeaderSection
                                .id("syncStatsListTop")
                        
                            // Current Status Section
                            cyberpunkStatusSection
                        
                            // Performance Metrics Section
                            cyberpunkPerformanceSection
                        
                            // System Resources Section
                            cyberpunkSystemSection
                        
                            // Actions Section
                            cyberpunkActionsSection
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                    }
                    .scrollPosition($scrollPosition)
                    .background(
                        // Scroll position detection
                        GeometryReader { geometry in
                            Color.clear
                                .onChange(of: geometry.frame(in: .global).minY) { _, newY in
                                    let newIsAtTop = newY >= -10
                                    if newIsAtTop != isAtTop {
                                        isAtTop = newIsAtTop
                                        tabNavigation.updateScrollPosition(for: 2, isAtTop: newIsAtTop, scrollOffset: newY)
                                    }
                                }
                        }
                    )
                }
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            tabNavigation.setNavigationState(for: 2, inSubview: true, level: 1)
            tabNavigation.resetScrollState(for: 2)
            isAtTop = true
            tabNavigation.updateScrollPosition(for: 2, isAtTop: true)
            
            startCyberpunkAnimations()
            Task {
                await refreshData()
            }
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
    
    // MARK: - Cyberpunk Animation Control
    
    private func startCyberpunkAnimations() {
        // Grid movement animation
        withAnimation(.linear(duration: 30).repeatForever(autoreverses: false)) {
            gridOffset = 200
        }
        
        // Pulse animation
        withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
            pulseIntensity = 1.0
        }
        
        // Data stream animation
        withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) {
            dataStreamOffset = 100
        }
    }
    
    // MARK: - Cyberpunk Header Section
    
    private var cyberpunkHeaderSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("SYNC")
                    .font(.system(size: 32, weight: .black, design: .monospaced))
                    .foregroundColor(.white)
                    .shadow(color: .cyan, radius: 2 + pulseIntensity * 2)
                    .accessibilityLabel("Sync")
                
                Text("STATISTICS")
                    .font(.system(size: 32, weight: .black, design: .monospaced))
                    .foregroundColor(.cyan)
                    .shadow(color: .cyan, radius: 2 + pulseIntensity * 2)
                    .accessibilityLabel("Statistics")
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Sync Statistics")
            
            Spacer()
            
            // System status indicator
            CyberpunkStatusIndicator(isActive: coordinator.isAutoSyncing)
                .accessibilityLabel(coordinator.isAutoSyncing ? "System active" : "System idle")
            
            // Back button
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .padding(8)
                    .background(
                        Circle()
                            .fill(Color.red.opacity(0.8))
                            .overlay(
                                Circle()
                                    .stroke(Color.red, lineWidth: 1)
                            )
                    )
            }
            .accessibilityLabel("Close")
            .accessibilityHint("Double tap to close sync statistics")
        }
        .padding(.vertical, 8)
    }
    
    // MARK: - Cyberpunk Status Section
    
    private var cyberpunkStatusSection: some View {
        CyberpunkPanel {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("SYSTEM STATUS")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(.cyan)
                    
                    Spacer()
                    
                    CyberpunkDataStream(offset: dataStreamOffset)
                }
                
                VStack(spacing: 12) {
                    CyberpunkStatusRow(
                        label: "SYNC STATE",
                        value: coordinator.isAutoSyncing ? "ACTIVE" : "IDLE",
                        status: coordinator.isAutoSyncing ? .active : .idle
                    )
                    
                    CyberpunkStatusRow(
                        label: "AUTO-SYNC",
                        value: coordinator.autoSyncEnabled ? "ENABLED" : "DISABLED",
                        status: coordinator.autoSyncEnabled ? .active : .error
                    )
                    
                    CyberpunkStatusRow(
                        label: "NETWORK",
                        value: "CONNECTED",
                        status: .active
                    )
                    
                    if let lastSync = coordinator.lastAutoSyncTime {
                        CyberpunkStatusRow(
                            label: "LAST SYNC",
                            value: formatLastSyncTime(lastSync),
                            status: .idle
                        )
                    }
                }
            }
        }
    }
    
    // MARK: - Cyberpunk Performance Section
    
    private var cyberpunkPerformanceSection: some View {
        CyberpunkPanel {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("PERFORMANCE MATRIX")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(.green)
                    
                    Spacer()
                    
                    Text("[\(coordinator.performanceMetrics.count) RECORDS]")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.gray)
                }
                
                if coordinator.performanceMetrics.isEmpty {
                    CyberpunkNoDataView(message: "NO PERFORMANCE DATA AVAILABLE")
                } else {
                    // Performance grid
                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 12) {
                        CyberpunkMetricCard(
                            title: "AVG DURATION",
                            value: formatAverageDuration(),
                            icon: "clock",
                            color: .purple
                        )
                        
                        CyberpunkMetricCard(
                            title: "SUCCESS RATE",
                            value: "\(Int(calculateSuccessRate() * 100))%",
                            icon: "checkmark.circle",
                            color: .green
                        )
                        
                        CyberpunkMetricCard(
                            title: "AVG SCORE",
                            value: "\(Int(calculateAverageScore()))",
                            icon: "chart.bar",
                            color: .orange
                        )
                        
                        CyberpunkMetricCard(
                            title: "TOTAL OPS",
                            value: "\(coordinator.performanceMetrics.count)",
                            icon: "number",
                            color: .blue
                        )
                    }
                    
                    // Recent operations log
                    if !coordinator.performanceMetrics.isEmpty {
                        Divider()
                            .background(Color.gray.opacity(0.3))
                        
                        Text("RECENT OPERATIONS")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(.gray)
                        
                        LazyVStack(spacing: 6) {
                            ForEach(Array(coordinator.performanceMetrics.suffix(5).enumerated()), id: \.offset) { index, metric in
                                CyberpunkOperationRow(metric: metric, index: index)
                            }
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Cyberpunk System Section
    
    private var cyberpunkSystemSection: some View {
        CyberpunkPanel {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("SYSTEM RESOURCES")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(.orange)
                    
                    Spacer()
                    
                    Text("[REAL-TIME]")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.gray)
                        .opacity(0.5 + pulseIntensity * 0.5)
                }
                
                if let latestSnapshot = coordinator.resourceSnapshots.last {
                    VStack(spacing: 12) {
                        CyberpunkResourceBar(
                            label: "MEMORY",
                            value: latestSnapshot.memoryUsageMB,
                            maxValue: latestSnapshot.memoryUsageMB + latestSnapshot.availableMemoryMB,
                            unit: "MB",
                            color: memoryColor(latestSnapshot.memoryPressure)
                        )
                        
                        if let batteryLevel = latestSnapshot.batteryLevel {
                            CyberpunkResourceBar(
                                label: "BATTERY",
                                value: Double(batteryLevel * 100),
                                maxValue: 100,
                                unit: "%",
                                color: batteryColor(batteryLevel)
                            )
                        }
                        
                        CyberpunkStatusRow(
                            label: "THERMAL STATE",
                            value: thermalStateText(latestSnapshot.thermalState),
                            status: thermalStateStatus(latestSnapshot.thermalState)
                        )
                        
                        CyberpunkStatusRow(
                            label: "POWER MODE",
                            value: latestSnapshot.lowPowerModeEnabled ? "LOW POWER" : "NORMAL",
                            status: latestSnapshot.lowPowerModeEnabled ? .warning : .active
                        )
                    }
                } else {
                    CyberpunkNoDataView(message: "NO SYSTEM DATA AVAILABLE")
                }
            }
        }
    }
    
    // MARK: - Cyberpunk Actions Section
    
    private var cyberpunkActionsSection: some View {
        CyberpunkPanel {
            VStack(alignment: .leading, spacing: 16) {
                Text("ACTIONS")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(.red)
                
                VStack(spacing: 12) {
                    CyberpunkActionButton(
                        title: "REFRESH DATA",
                        icon: "arrow.clockwise",
                        color: .blue,
                        action: {
                            Task {
                                await refreshData()
                            }
                        }
                    )
                    
                    CyberpunkActionButton(
                        title: "CLEAR HISTORY",
                        icon: "trash",
                        color: .red,
                        action: {
                            showingClearAlert = true
                        }
                    )
                }
                
                Text("[\(coordinator.performanceMetrics.count) METRICS • \(coordinator.resourceSnapshots.count) SNAPSHOTS]")
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundColor(.gray)
                    .opacity(0.7)
            }
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
    
    // MARK: - Cyberpunk Utility Functions
    
    private func formatLastSyncTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
    
    private func formatAverageDuration() -> String {
        guard !coordinator.performanceMetrics.isEmpty else { return "0.0s" }
        let avg = coordinator.performanceMetrics.map { $0.duration }.reduce(0, +) / Double(coordinator.performanceMetrics.count)
        return String(format: "%.1fs", avg)
    }
    
    private func calculateSuccessRate() -> Double {
        guard !coordinator.performanceMetrics.isEmpty else { return 0 }
        let successful = coordinator.performanceMetrics.filter { $0.success }.count
        return Double(successful) / Double(coordinator.performanceMetrics.count)
    }
    
    private func calculateAverageScore() -> Double {
        guard !coordinator.performanceMetrics.isEmpty else { return 0 }
        return coordinator.performanceMetrics.map { $0.performanceScore }.reduce(0, +) / Double(coordinator.performanceMetrics.count)
    }
    
    private func memoryColor(_ pressure: AutoSyncCoordinator.SystemResourceSnapshot.MemoryPressure) -> Color {
        switch pressure {
        case .normal: return .green
        case .warning: return .yellow
        case .critical: return .red
        }
    }
    
    private func batteryColor(_ level: Float) -> Color {
        if level >= 0.5 { return .green }
        else if level >= 0.2 { return .yellow }
        else { return .red }
    }
    
    private func thermalStateText(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "NOMINAL"
        case .fair: return "FAIR"
        case .serious: return "SERIOUS"
        case .critical: return "CRITICAL"
        @unknown default: return "UNKNOWN"
        }
    }
    
    private func thermalStateStatus(_ state: ProcessInfo.ThermalState) -> CyberpunkStatus {
        switch state {
        case .nominal: return .active
        case .fair: return .warning
        case .serious, .critical: return .error
        @unknown default: return .idle
        }
    }
}

// MARK: - Cyberpunk UI Components

struct CyberpunkBackgroundView: View {
    @Binding var gridOffset: CGFloat
    @State private var isVisible = true
    
    var body: some View {
        ZStack {
            // Dark base
            Color.black.ignoresSafeArea()
            
            // Animated grid - only when visible
            if isVisible {
                CyberpunkGrid(offset: gridOffset)
                    .opacity(0.2)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            isVisible = false // Pause animations when app goes to background
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            isVisible = true // Resume animations when app becomes active
        }
    }
}

struct CyberpunkGrid: View {
    let offset: CGFloat
    
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 40
            let strokeWidth: CGFloat = 0.5
            
            // Pre-calculate bounds for performance
            let minX = -spacing
            let maxX = size.width + spacing
            let minY = -spacing
            let maxY = size.height + spacing
            
            // Vertical lines - optimized loop
            let verticalStart = Int(minX / spacing) - 1
            let verticalEnd = Int(maxX / spacing) + 1
            
            for i in verticalStart...verticalEnd {
                let x = CGFloat(i) * spacing
                let adjustedX = (x + offset).truncatingRemainder(dividingBy: size.width + spacing * 2)
                if adjustedX >= 0 && adjustedX <= size.width {
                    context.stroke(
                        Path { path in
                            path.move(to: CGPoint(x: adjustedX, y: 0))
                            path.addLine(to: CGPoint(x: adjustedX, y: size.height))
                        },
                        with: .color(.cyan.opacity(0.3)),
                        lineWidth: strokeWidth
                    )
                }
            }
            
            // Horizontal lines - optimized loop
            let horizontalStart = Int(minY / spacing) - 1
            let horizontalEnd = Int(maxY / spacing) + 1
            
            for i in horizontalStart...horizontalEnd {
                let y = CGFloat(i) * spacing
                let adjustedY = (y + offset * 0.7).truncatingRemainder(dividingBy: size.height + spacing * 2)
                if adjustedY >= 0 && adjustedY <= size.height {
                    context.stroke(
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: adjustedY))
                            path.addLine(to: CGPoint(x: size.width, y: adjustedY))
                        },
                        with: .color(.cyan.opacity(0.3)),
                        lineWidth: strokeWidth
                    )
                }
            }
        }
        .drawingGroup() // Enable Metal rendering for better performance
    }
}

struct CyberpunkLoadingView: View {
    @State private var loadingProgress: Double = 0
    
    var body: some View {
        VStack(spacing: 20) {
            Text("INITIALIZING SYNC MATRIX")
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundColor(.cyan)
            
            CyberpunkProgressBar(progress: loadingProgress)
                .frame(height: 6)
            
            Text("LOADING PERFORMANCE DATA...")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.gray)
        }
        .padding(20)
        .onAppear {
            withAnimation(.linear(duration: 2)) {
                loadingProgress = 1.0
            }
        }
    }
}

struct CyberpunkStatusIndicator: View {
    let isActive: Bool
    @State private var pulse: Double = 0
    
    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.green.opacity(0.3), lineWidth: 2)
                .frame(width: 40, height: 40)
            
            Circle()
                .fill(isActive ? Color.cyan : Color.green)
                .frame(width: 12, height: 12)
                .scaleEffect(1 + pulse * 0.3)
                .opacity(0.8 + pulse * 0.2)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                pulse = 1
            }
        }
    }
}

struct CyberpunkPanel<Content: View>: View {
    let content: Content
    
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    
    var body: some View {
        content
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.cyan.opacity(0.3), lineWidth: 1)
                    )
            )
    }
}

struct CyberpunkDataStream: View {
    let offset: CGFloat
    
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<8, id: \.self) { _ in
                Rectangle()
                    .fill(Color.cyan.opacity(0.6))
                    .frame(width: 2, height: CGFloat.random(in: 4...12))
            }
        }
        .offset(x: offset * 0.5)
    }
}

enum CyberpunkStatus {
    case active, idle, warning, error
    
    var color: Color {
        switch self {
        case .active: return .green
        case .idle: return .gray
        case .warning: return .yellow
        case .error: return .red
        }
    }
}

struct CyberpunkStatusRow: View {
    let label: String
    let value: String
    let status: CyberpunkStatus
    
    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.gray)
            
            Spacer()
            
            HStack(spacing: 8) {
                Circle()
                    .fill(status.color)
                    .frame(width: 6, height: 6)
                
                Text(value)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(status.color)
            }
        }
    }
}

struct CyberpunkMetricCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    @State private var flicker: Double = 0
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                    .font(.system(size: 12))
                
                Spacer()
                
                Text(title)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.gray)
            }
            
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .opacity(0.9 + flicker * 0.1)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(color.opacity(0.4), lineWidth: 1)
                )
        )
        .onAppear {
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                flicker = 1
            }
        }
    }
}

struct CyberpunkOperationRow: View {
    let metric: AutoSyncCoordinator.PerformanceMetric
    let index: Int
    
    @State private var appeared = false
    
    var body: some View {
        HStack(spacing: 8) {
            Text(formatTime(metric.timestamp))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.gray)
                .frame(width: 50, alignment: .leading)
            
            Circle()
                .fill(metric.success ? Color.green : Color.red)
                .frame(width: 4, height: 4)
            
            Text(metric.context.rawValue.uppercased())
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 60, alignment: .leading)
            
            Spacer()
            
            Text("\(metric.articlesProcessed)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.cyan)
                .frame(width: 25, alignment: .trailing)
            
            Text(String(format: "%.1fs", metric.duration))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.purple)
                .frame(width: 35, alignment: .trailing)
        }
        .opacity(appeared ? 1 : 0)
        .offset(x: appeared ? 0 : 20)
        .onAppear {
            withAnimation(.easeOut(duration: 0.3).delay(Double(index) * 0.1)) {
                appeared = true
            }
        }
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

struct CyberpunkResourceBar: View {
    let label: String
    let value: Double
    let maxValue: Double
    let unit: String
    let color: Color
    
    @State private var animatedValue: Double = 0
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.gray)
                
                Spacer()
                
                Text(String(format: "%.1f%@", value, unit))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(color)
            }
            
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(height: 6)
                    
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.8), color],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geometry.size.width * (animatedValue / maxValue), height: 6)
                    
                    // Scanning line effect
                    Rectangle()
                        .fill(Color.white.opacity(0.8))
                        .frame(width: 2, height: 8)
                        .offset(x: geometry.size.width * (animatedValue / maxValue) - 1)
                }
            }
            .frame(height: 6)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1)) {
                animatedValue = value
            }
        }
        .onChange(of: value) { _, newValue in
            withAnimation(.easeInOut(duration: 0.5)) {
                animatedValue = newValue
            }
        }
    }
}

struct CyberpunkProgressBar: View {
    let progress: Double
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.cyan, .blue],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geometry.size.width * progress)
                
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2)
                    .offset(x: geometry.size.width * progress - 1)
            }
        }
    }
}

struct CyberpunkNoDataView: View {
    let message: String
    
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundColor(.yellow)
            
            Text(message)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.4))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.yellow.opacity(0.3), lineWidth: 1)
                )
        )
    }
}

struct CyberpunkActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void
    
    @State private var isPressed = false
    
    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))
                
                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(color.opacity(isPressed ? 0.8 : 0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(color, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(PlainButtonStyle())
        .scaleEffect(isPressed ? 0.95 : 1.0)
        .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity, pressing: { pressing in
            withAnimation(.easeInOut(duration: 0.1)) {
                isPressed = pressing
            }
        }, perform: {})
    }
}

#Preview {
    NavigationView {
        SyncStatisticsView()
    }
}
