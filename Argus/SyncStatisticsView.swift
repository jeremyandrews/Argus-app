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
    
    // Cyberpunk detail view states
    @State private var showingDetailView = false
    @State private var detailViewType: CyberpunkDetailType = .duration
    
    enum CyberpunkDetailType {
        case duration, successRate, performance, operations
    }
    
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
        .overlay {
            if showingDetailView {
                CyberpunkDetailOverlay(
                    detailType: detailViewType,
                    coordinator: coordinator,
                    isPresented: $showingDetailView
                )
            }
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
                            color: .purple,
                            onTap: {
                                detailViewType = .duration
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    showingDetailView = true
                                }
                            }
                        )
                        
                        CyberpunkMetricCard(
                            title: "SUCCESS RATE",
                            value: "\(Int(calculateSuccessRate() * 100))%",
                            icon: "checkmark.circle",
                            color: .green,
                            onTap: {
                                detailViewType = .successRate
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    showingDetailView = true
                                }
                            }
                        )
                        
                        CyberpunkMetricCard(
                            title: "AVG SCORE",
                            value: "\(Int(calculateAverageScore()))",
                            icon: "chart.bar",
                            color: .orange,
                            onTap: {
                                detailViewType = .performance
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    showingDetailView = true
                                }
                            }
                        )
                        
                        CyberpunkMetricCard(
                            title: "TOTAL OPS",
                            value: "\(coordinator.performanceMetrics.count)",
                            icon: "number",
                            color: .blue,
                            onTap: {
                                detailViewType = .operations
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    showingDetailView = true
                                }
                            }
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
    
    // MARK: - Detail Analysis Functions
    
    private func getDurationAnalysisDetails() -> String {
        guard !coordinator.performanceMetrics.isEmpty else {
            return "NO DATA AVAILABLE\n\nInsufficient performance data to provide duration analysis."
        }
        
        let durations = coordinator.performanceMetrics.map { $0.duration }
        let avg = durations.reduce(0, +) / Double(durations.count)
        let min = durations.min() ?? 0
        let max = durations.max() ?? 0
        let median = durations.sorted()[durations.count / 2]
        
        let recentTrend = durations.suffix(5).reduce(0, +) / Double(Swift.min(5, durations.count))
        let trendIndicator = recentTrend > avg ? "INCREASING" : recentTrend < avg ? "DECREASING" : "STABLE"
        
        return """
        DURATION PERFORMANCE ANALYSIS
        
        STATISTICS:
        • Average: \(String(format: "%.2f", avg))s
        • Minimum: \(String(format: "%.2f", min))s  
        • Maximum: \(String(format: "%.2f", max))s
        • Median: \(String(format: "%.2f", median))s
        
        RECENT TREND: \(trendIndicator)
        
        ANALYSIS:
        \(avg < 2.0 ? "✓ Excellent performance" : avg < 5.0 ? "⚠ Moderate performance" : "⛔ Performance needs attention")
        
        TOTAL OPERATIONS: \(coordinator.performanceMetrics.count)
        """
    }
    
    private func getSuccessRateDetails() -> String {
        guard !coordinator.performanceMetrics.isEmpty else {
            return "NO DATA AVAILABLE\n\nInsufficient performance data to provide success rate analysis."
        }
        
        let total = coordinator.performanceMetrics.count
        let successful = coordinator.performanceMetrics.filter { $0.success }.count
        let failed = total - successful
        let rate = Double(successful) / Double(total) * 100
        
        let recentOperations = coordinator.performanceMetrics.suffix(10)
        let recentSuccessful = recentOperations.filter { $0.success }.count
        let recentRate = Double(recentSuccessful) / Double(recentOperations.count) * 100
        
        let contexts = Dictionary(grouping: coordinator.performanceMetrics, by: { $0.context })
        let contextStats = contexts.map { context, metrics in
            let contextSuccessful = metrics.filter { $0.success }.count
            let contextRate = Double(contextSuccessful) / Double(metrics.count) * 100
            return "\(context.rawValue.uppercased()): \(Int(contextRate))%"
        }.joined(separator: "\n")
        
        return """
        SUCCESS RATE BREAKDOWN
        
        OVERALL STATISTICS:
        • Success Rate: \(Int(rate))%
        • Successful Operations: \(successful)
        • Failed Operations: \(failed)
        • Total Operations: \(total)
        
        RECENT TREND (Last 10):
        • Recent Success Rate: \(Int(recentRate))%
        • Trend: \(recentRate > rate ? "IMPROVING" : recentRate < rate ? "DECLINING" : "STABLE")
        
        BY CONTEXT:
        \(contextStats)
        
        STATUS: \(rate >= 95 ? "✓ Excellent" : rate >= 85 ? "⚠ Good" : rate >= 70 ? "⚠ Fair" : "⛔ Poor")
        """
    }
    
    private func getPerformanceScoreDetails() -> String {
        guard !coordinator.performanceMetrics.isEmpty else {
            return "NO DATA AVAILABLE\n\nInsufficient performance data to provide performance score analysis."
        }
        
        let scores = coordinator.performanceMetrics.map { $0.performanceScore }
        let avg = scores.reduce(0, +) / Double(scores.count)
        let min = scores.min() ?? 0
        let max = scores.max() ?? 0
        
        let excellent = scores.filter { $0 >= 90 }.count
        let good = scores.filter { $0 >= 70 && $0 < 90 }.count
        let fair = scores.filter { $0 >= 50 && $0 < 70 }.count
        let poor = scores.filter { $0 < 50 }.count
        
        let recentScores = scores.suffix(5)
        let recentAvg = recentScores.reduce(0, +) / Double(recentScores.count)
        let trend = recentAvg > avg + 5 ? "IMPROVING" : recentAvg < avg - 5 ? "DECLINING" : "STABLE"
        
        return """
        PERFORMANCE SCORE ANALYSIS
        
        SCORE STATISTICS:
        • Average Score: \(Int(avg))
        • Minimum Score: \(Int(min))
        • Maximum Score: \(Int(max))
        
        DISTRIBUTION:
        • Excellent (90+): \(excellent) operations
        • Good (70-89): \(good) operations  
        • Fair (50-69): \(fair) operations
        • Poor (<50): \(poor) operations
        
        RECENT TREND: \(trend)
        • Recent Average: \(Int(recentAvg))
        
        PERFORMANCE GRADE:
        \(avg >= 90 ? "A+ EXCELLENT" : avg >= 80 ? "B+ GOOD" : avg >= 70 ? "C+ FAIR" : avg >= 60 ? "D POOR" : "F CRITICAL")
        """
    }
    
    private func getOperationsHistoryDetails() -> String {
        let total = coordinator.performanceMetrics.count
        guard total > 0 else {
            return "NO OPERATIONS DATA\n\nNo sync operations have been recorded yet. Performance tracking begins after the first sync operation."
        }
        
        let totalArticles = coordinator.performanceMetrics.map { $0.articlesProcessed }.reduce(0, +)
        let totalDuration = coordinator.performanceMetrics.map { $0.duration }.reduce(0, +)
        let avgArticlesPerOp = Double(totalArticles) / Double(total)
        let throughput = Double(totalArticles) / totalDuration
        
        let contexts = Dictionary(grouping: coordinator.performanceMetrics, by: { $0.context })
        let contextBreakdown = contexts.map { context, metrics in
            "\(context.rawValue.uppercased()): \(metrics.count) ops"
        }.joined(separator: "\n")
        
        let timeRange = coordinator.performanceMetrics.isEmpty ? "N/A" : 
            self.formatTime(coordinator.performanceMetrics.first!.timestamp) + " - " + 
            self.formatTime(coordinator.performanceMetrics.last!.timestamp)
        
        let recentOps = coordinator.performanceMetrics.suffix(5)
        let recentSummary = recentOps.map { metric in
            let status = metric.success ? "✓" : "✗"
            return "\(status) \(self.formatTime(metric.timestamp)) - \(metric.articlesProcessed) articles"
        }.joined(separator: "\n")
        
        return """
        OPERATIONS HISTORY
        
        SUMMARY:
        • Total Operations: \(total)
        • Total Articles Processed: \(totalArticles)
        • Total Processing Time: \(String(format: "%.1f", totalDuration))s
        • Average Articles/Operation: \(String(format: "%.1f", avgArticlesPerOp))
        • Throughput: \(String(format: "%.1f", throughput)) articles/sec
        
        TIME RANGE: \(timeRange)
        
        BY CONTEXT:
        \(contextBreakdown)
        
        RECENT OPERATIONS:
        \(recentSummary)
        """
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
    let onTap: () -> Void
    
    @State private var flicker: Double = 0
    @State private var isPressed = false
    
    var body: some View {
        Button(action: onTap) {
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
                    .fill(Color.black.opacity(isPressed ? 0.8 : 0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(color.opacity(isPressed ? 0.6 : 0.4), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(PlainButtonStyle())
        .scaleEffect(isPressed ? 0.98 : 1.0)
        .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity, pressing: { pressing in
            withAnimation(.easeInOut(duration: 0.1)) {
                isPressed = pressing
            }
        }, perform: {})
        .onAppear {
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                flicker = 1
            }
        }
        .accessibilityLabel("\(title): \(value)")
        .accessibilityHint("Double tap for detailed analysis")
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

// MARK: - Cyberpunk Detail Overlay

struct CyberpunkDetailOverlay: View {
    let detailType: SyncStatisticsView.CyberpunkDetailType
    let coordinator: AutoSyncCoordinator
    @Binding var isPresented: Bool
    
    @State private var scanLineOffset: CGFloat = 0
    @State private var borderPulse: Double = 0
    
    var body: some View {
        ZStack {
            // Semi-transparent background
            Color.black.opacity(0.8)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isPresented = false
                    }
                }
            
            // Detail panel
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    Text(headerTitle)
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundColor(.cyan)
                    
                    Spacer()
                    
                    // Close button
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            isPresented = false
                        }
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
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
                    .accessibilityLabel("Close details")
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                
                // Content
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        detailContent
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.black.opacity(0.95))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(
                                LinearGradient(
                                    colors: [.cyan.opacity(0.3 + borderPulse * 0.3), .blue.opacity(0.3 + borderPulse * 0.3)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 2
                            )
                    )
                    .overlay(
                        // Scanning line effect
                        Rectangle()
                            .fill(Color.cyan.opacity(0.1))
                            .frame(height: 2)
                            .offset(y: scanLineOffset)
                            .animation(.linear(duration: 3).repeatForever(autoreverses: false), value: scanLineOffset)
                    )
                    .clipped()
            )
            .padding(.horizontal, 30)
            .padding(.vertical, 60)
        }
        .onAppear {
            withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) {
                scanLineOffset = 400
            }
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                borderPulse = 1.0
            }
        }
    }
    
    private var headerTitle: String {
        switch detailType {
        case .duration: return "DURATION ANALYSIS"
        case .successRate: return "SUCCESS RATE BREAKDOWN"
        case .performance: return "PERFORMANCE METRICS"
        case .operations: return "OPERATIONS HISTORY"
        }
    }
    
    @ViewBuilder
    private var detailContent: some View {
        switch detailType {
        case .duration:
            CyberpunkDurationDetails(coordinator: coordinator)
        case .successRate:
            CyberpunkSuccessRateDetails(coordinator: coordinator)
        case .performance:
            CyberpunkPerformanceDetails(coordinator: coordinator)
        case .operations:
            CyberpunkOperationsDetails(coordinator: coordinator)
        }
    }
}

// MARK: - Detail Components

struct CyberpunkDurationDetails: View {
    let coordinator: AutoSyncCoordinator
    
    var body: some View {
        if coordinator.performanceMetrics.isEmpty {
            CyberpunkNoDataView(message: "NO DURATION DATA AVAILABLE")
        } else {
            let durations = coordinator.performanceMetrics.map { $0.duration }
            let avg = durations.reduce(0, +) / Double(durations.count)
            let min = durations.min() ?? 0
            let max = durations.max() ?? 0
            let median = durations.sorted()[durations.count / 2]
            
            VStack(alignment: .leading, spacing: 12) {
                CyberpunkStatCard(label: "AVERAGE", value: String(format: "%.2fs", avg), color: .cyan)
                CyberpunkStatCard(label: "MINIMUM", value: String(format: "%.2fs", min), color: .green)
                CyberpunkStatCard(label: "MAXIMUM", value: String(format: "%.2fs", max), color: .red)
                CyberpunkStatCard(label: "MEDIAN", value: String(format: "%.2fs", median), color: .purple)
                
                Divider().background(Color.gray.opacity(0.3))
                
                let recentTrend = durations.suffix(5).reduce(0, +) / Double(Swift.min(5, durations.count))
                let trendIndicator = recentTrend > avg ? "INCREASING" : recentTrend < avg ? "DECREASING" : "STABLE"
                let trendColor: Color = recentTrend > avg ? .red : recentTrend < avg ? .green : .gray
                
                CyberpunkTrendCard(
                    title: "RECENT TREND",
                    value: trendIndicator,
                    color: trendColor,
                    description: "Based on last 5 operations"
                )
                
                CyberpunkAssessmentCard(
                    assessment: avg < 2.0 ? "✓ EXCELLENT PERFORMANCE" : avg < 5.0 ? "⚠ MODERATE PERFORMANCE" : "⛔ PERFORMANCE NEEDS ATTENTION",
                    color: avg < 2.0 ? .green : avg < 5.0 ? .orange : .red
                )
            }
        }
    }
}

struct CyberpunkSuccessRateDetails: View {
    let coordinator: AutoSyncCoordinator
    
    var body: some View {
        if coordinator.performanceMetrics.isEmpty {
            CyberpunkNoDataView(message: "NO SUCCESS RATE DATA AVAILABLE")
        } else {
            let total = coordinator.performanceMetrics.count
            let successful = coordinator.performanceMetrics.filter { $0.success }.count
            let failed = total - successful
            let rate = Double(successful) / Double(total) * 100
            
            VStack(alignment: .leading, spacing: 12) {
                CyberpunkStatCard(label: "SUCCESS RATE", value: "\(Int(rate))%", color: rate >= 90 ? .green : rate >= 70 ? .orange : .red)
                CyberpunkStatCard(label: "SUCCESSFUL OPS", value: "\(successful)", color: .green)
                CyberpunkStatCard(label: "FAILED OPS", value: "\(failed)", color: .red)
                CyberpunkStatCard(label: "TOTAL OPS", value: "\(total)", color: .cyan)
                
                Divider().background(Color.gray.opacity(0.3))
                
                let recentOperations = coordinator.performanceMetrics.suffix(10)
                let recentSuccessful = recentOperations.filter { $0.success }.count
                let recentRate = Double(recentSuccessful) / Double(recentOperations.count) * 100
                
                CyberpunkTrendCard(
                    title: "RECENT TREND",
                    value: recentRate > rate ? "IMPROVING" : recentRate < rate ? "DECLINING" : "STABLE",
                    color: recentRate > rate ? .green : recentRate < rate ? .red : .gray,
                    description: "Last 10 operations: \(Int(recentRate))%"
                )
                
                CyberpunkContextBreakdown(coordinator: coordinator)
            }
        }
    }
}

struct CyberpunkPerformanceDetails: View {
    let coordinator: AutoSyncCoordinator
    
    var body: some View {
        if coordinator.performanceMetrics.isEmpty {
            CyberpunkNoDataView(message: "NO PERFORMANCE DATA AVAILABLE")
        } else {
            let scores = coordinator.performanceMetrics.map { $0.performanceScore }
            let avg = scores.reduce(0, +) / Double(scores.count)
            let min = scores.min() ?? 0
            let max = scores.max() ?? 0
            
            VStack(alignment: .leading, spacing: 12) {
                CyberpunkStatCard(label: "AVERAGE SCORE", value: "\(Int(avg))", color: .cyan)
                CyberpunkStatCard(label: "MINIMUM SCORE", value: "\(Int(min))", color: .red)
                CyberpunkStatCard(label: "MAXIMUM SCORE", value: "\(Int(max))", color: .green)
                
                Divider().background(Color.gray.opacity(0.3))
                
                let excellent = scores.filter { $0 >= 90 }.count
                let good = scores.filter { $0 >= 70 && $0 < 90 }.count
                let fair = scores.filter { $0 >= 50 && $0 < 70 }.count
                let poor = scores.filter { $0 < 50 }.count
                
                Text("DISTRIBUTION")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.gray)
                
                VStack(spacing: 8) {
                    CyberpunkStatCard(label: "EXCELLENT (90+)", value: "\(excellent)", color: .green)
                    CyberpunkStatCard(label: "GOOD (70-89)", value: "\(good)", color: .blue)
                    CyberpunkStatCard(label: "FAIR (50-69)", value: "\(fair)", color: .orange)
                    CyberpunkStatCard(label: "POOR (<50)", value: "\(poor)", color: .red)
                }
                
                Divider().background(Color.gray.opacity(0.3))
                
                let grade = avg >= 90 ? "A+ EXCELLENT" : avg >= 80 ? "B+ GOOD" : avg >= 70 ? "C+ FAIR" : avg >= 60 ? "D POOR" : "F CRITICAL"
                let gradeColor: Color = avg >= 90 ? .green : avg >= 80 ? .blue : avg >= 70 ? .orange : avg >= 60 ? .red : .red
                
                CyberpunkAssessmentCard(assessment: grade, color: gradeColor)
            }
        }
    }
}

struct CyberpunkOperationsDetails: View {
    let coordinator: AutoSyncCoordinator
    
    var body: some View {
        let total = coordinator.performanceMetrics.count
        
        if total == 0 {
            CyberpunkNoDataView(message: "NO OPERATIONS DATA AVAILABLE")
        } else {
            let totalArticles = coordinator.performanceMetrics.map { $0.articlesProcessed }.reduce(0, +)
            let totalDuration = coordinator.performanceMetrics.map { $0.duration }.reduce(0, +)
            let avgArticlesPerOp = Double(totalArticles) / Double(total)
            let throughput = Double(totalArticles) / totalDuration
            
            VStack(alignment: .leading, spacing: 12) {
                CyberpunkStatCard(label: "TOTAL OPS", value: "\(total)", color: .cyan)
                CyberpunkStatCard(label: "TOTAL ARTICLES", value: "\(totalArticles)", color: .green)
                CyberpunkStatCard(label: "TOTAL TIME", value: String(format: "%.1fs", totalDuration), color: .purple)
                CyberpunkStatCard(label: "AVG ARTICLES/OP", value: String(format: "%.1f", avgArticlesPerOp), color: .orange)
                CyberpunkStatCard(label: "THROUGHPUT", value: String(format: "%.1f/s", throughput), color: .blue)
                
                Divider().background(Color.gray.opacity(0.3))
                
                CyberpunkContextBreakdown(coordinator: coordinator)
                
                Divider().background(Color.gray.opacity(0.3))
                
                Text("RECENT OPERATIONS")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.gray)
                
                LazyVStack(spacing: 6) {
                    ForEach(Array(coordinator.performanceMetrics.suffix(8).enumerated()), id: \.offset) { index, metric in
                        HStack {
                            Text(formatTime(metric.timestamp))
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(.gray)
                                .frame(width: 50, alignment: .leading)
                            
                            Circle()
                                .fill(metric.success ? Color.green : Color.red)
                                .frame(width: 4, height: 4)
                            
                            Text(metric.context.rawValue.uppercased())
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(.white)
                                .frame(width: 60, alignment: .leading)
                            
                            Spacer()
                            
                            Text("\(metric.articlesProcessed)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(.cyan)
                        }
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.3))
                    }
                }
            }
        }
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - Supporting Detail Components

struct CyberpunkStatCard: View {
    let label: String
    let value: String
    let color: Color
    
    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.gray)
            
            Spacer()
            
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(color)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color.black.opacity(0.3))
    }
}

struct CyberpunkTrendCard: View {
    let title: String
    let value: String
    let color: Color
    let description: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.gray)
                
                Spacer()
                
                Text(value)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(color)
            }
            
            Text(description)
                .font(.system(size: 9, weight: .regular, design: .monospaced))
                .foregroundColor(.gray.opacity(0.7))
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.3))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(color.opacity(0.3), lineWidth: 1)
                )
        )
    }
}

struct CyberpunkAssessmentCard: View {
    let assessment: String
    let color: Color
    
    var body: some View {
        HStack {
            Text(assessment)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(color)
            
            Spacer()
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(color.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(color.opacity(0.3), lineWidth: 1)
                )
        )
    }
}

struct CyberpunkContextBreakdown: View {
    let coordinator: AutoSyncCoordinator
    
    var body: some View {
        let contexts = Dictionary(grouping: coordinator.performanceMetrics, by: { $0.context })
        
        VStack(alignment: .leading, spacing: 8) {
            Text("BY CONTEXT")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(.gray)
            
            ForEach(Array(contexts.keys.sorted(by: { $0.rawValue < $1.rawValue })), id: \.self) { context in
                if let metrics = contexts[context] {
                    let contextSuccessful = metrics.filter { $0.success }.count
                    let contextRate = Double(contextSuccessful) / Double(metrics.count) * 100
                    
                    CyberpunkStatCard(
                        label: context.rawValue.uppercased(),
                        value: "\(metrics.count) ops (\(Int(contextRate))%)",
                        color: contextRate >= 90 ? .green : contextRate >= 70 ? .orange : .red
                    )
                }
            }
        }
    }
}

#Preview {
    NavigationView {
        SyncStatisticsView()
    }
}
