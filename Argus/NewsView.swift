import SwiftData
import SwiftUI
import UIKit

struct NewsView: View {
    // MARK: - View Model

    /// View model that manages article state and operations
    @StateObject var viewModel = NewsViewModel()

    // MARK: - Environment

    @Environment(\.editMode) private var editMode
    @Environment(\.modelContext) private var modelContext

    // MARK: - State

    /// UI State
    @State private var isFilterViewPresented: Bool = false
    @State private var filterViewHeight: CGFloat = 200
    @State private var showDeleteConfirmation = false
    @State private var articleToDelete: ArticleModel?
    @State var isActivelyScrolling: Bool = false
    @State private var scrollIdleTimer: Task<Void, Never>? = nil
    @State private var scrollProxy: ScrollViewProxy?
    @State private var needsScrollReset: Bool = false

    /// Tab bar height from parent view
    @Binding var tabBarHeight: CGFloat

    // MARK: - Computed Properties

    /// Message for delete confirmation dialog
    var deleteConfirmationMessage: String {
        if articleToDelete != nil {
            return "This article is bookmarked. Are you sure you want to delete it?"
        } else {
            let count = viewModel.selectedArticleIds.count
            return count == 1
                ? "Are you sure you want to delete this article?"
                : "Are you sure you want to delete \(count) articles?"
        }
    }

    /// Determines if any filter is active
    private var isAnyFilterActive: Bool {
        viewModel.showUnreadOnly || viewModel.showBookmarkedOnly
    }

    /// List of topics to show in topic bar
    private var visibleTopics: [String] {
        // Get unique topics from allArticles (which already match all non-topic filters)
        // No need to filter further since allArticles is already filtered by showUnreadOnly
        // and showBookmarkedOnly in the ViewModel
        let topics = Set(viewModel.allArticles.compactMap { $0.topic })
        return ["All"] + topics.sorted()
    }

    // MARK: - Body

    var body: some View {
        NavigationView {
            ZStack(alignment: .bottom) {
                // Main List containing header, topic bar, and articles
                List(selection: $viewModel.selectedArticleIds) {
                    // Header Section
                    Section {
                        headerView
                            .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .listRowSeparator(.hidden)

                        topicsBar
                            .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .listRowSeparator(.hidden)
                    }

                    // Content Section - either empty state or articles
                    if viewModel.filteredArticles.isEmpty {
                        Section {
                            emptyStateView
                                .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                                .listRowSeparator(.hidden)
                        }
                    } else {
                        // Build each group as a section
                        ForEach(viewModel.groupedArticles, id: \.key) { group in
                            if !group.key.isEmpty {
                                Section(header: Text(group.key)) {
                                    ForEach(group.articles.uniqued(), id: \.id) { article in
                                        ArticleRow(
                                            article: article,
                                            editMode: editMode,
                                            selectedArticleIDs: $viewModel.selectedArticleIds
                                        )
                                        .onAppear {
                                            loadMoreArticlesIfNeeded(currentItem: article)
                                        }
                                    }
                                }
                            } else {
                                // Single group with no header
                                ForEach(group.articles.uniqued(), id: \.id) { article in
                                    ArticleRow(
                                        article: article,
                                        editMode: editMode,
                                        selectedArticleIDs: $viewModel.selectedArticleIds
                                    )
                                    .onAppear {
                                        loadMoreArticlesIfNeeded(currentItem: article)
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .environment(\.editMode, editMode)
                // Pull-to-refresh for the entire list
                .refreshable {
                    Task {
                        await viewModel.syncWithServer()
                    }
                }
                // Add the toolbar item for the sync status in the navigation bar
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        SyncStatusIndicator(status: $viewModel.syncStatus)
                    }
                }
                // Edit mode handling
                .onChange(of: editMode?.wrappedValue) { _, newValue in
                    if newValue == .inactive {
                        viewModel.selectedArticleIds.removeAll()
                    }
                }
                // Notification handling
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ArticleViewed"))) { _ in
                    Task {
                        await viewModel.refreshWithAutoRedirectIfNeeded()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name("DetailViewClosed"))) { _ in
                    Task {
                        await viewModel.refreshWithAutoRedirectIfNeeded()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ArticleReadStatusChanged"))) { _ in
                    Task {
                        await viewModel.refreshWithAutoRedirectIfNeeded()
                    }
                }
                // Initial setup
                .onAppear {
                    Task {
                        await viewModel.refreshArticles()
                    }
                }
                // Handle scrolling for better performance
                .simultaneousGesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { _ in
                            if !isActivelyScrolling {
                                handleScrollBegin()
                            }
                        }
                )
                // Delete confirmation dialog
                .confirmationDialog(
                    deleteConfirmationMessage,
                    isPresented: $showDeleteConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) {
                        withAnimation {
                            if let article = articleToDelete {
                                Task {
                                    await viewModel.deleteArticle(article)
                                }
                                articleToDelete = nil
                            } else {
                                Task {
                                    await viewModel.performBatchOperation(.delete)
                                }
                            }
                        }
                    }
                    Button("Cancel", role: .cancel) {
                        articleToDelete = nil
                    }
                }

                // Filter sheet and edit toolbar
                if isFilterViewPresented {
                    filterSheet
                        .zIndex(1)
                }

                if editMode?.wrappedValue == .active {
                    editToolbar
                        .zIndex(1)
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    customEditButton()
                }
            }
        }
    }

    // Central handler for all filter changes
    private func handleFilterChange(topicChanged: Bool = false, newTopic: String? = nil, isDataChange _: Bool = false) {
        Task {
            // Handle topic changes
            if topicChanged, let newTopic = newTopic {
                await viewModel.applyTopicFilter(newTopic)
                needsScrollReset = true
            } else {
                // Just refresh with current filters
                await viewModel.refreshArticles()
            }

            // If we need to scroll to top after filter changes and we're not actively scrolling
            if needsScrollReset && !isActivelyScrolling {
                needsScrollReset = false
                // (Scroll reset logic would go here if we had direct scroll control)
            }
        }
    }

    // MARK: - Subviews

    /// Header view with logo and filter button
    var headerView: some View {
        HStack {
            Image("Argus")
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)
            Text("Argus")
                .font(.largeTitle)
                .bold()
            Spacer()
            Button(action: {
                withAnimation {
                    isFilterViewPresented.toggle()
                }
            }) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundColor(isAnyFilterActive ? .blue : .primary)
                    .padding(.leading, 8)
            }
        }
        .padding()
        .background(Color(UIColor.systemBackground))
    }

    /// Topic filtering bar
    var topicsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(visibleTopics, id: \.self) { topic in
                    Button {
                        withAnimation {
                            let lastTopic = viewModel.selectedTopic

                            Task {
                                await viewModel.applyTopicFilter(topic)
                            }

                            // Request scroll reset if topic changes
                            if lastTopic != topic {
                                needsScrollReset = true
                            }
                        }
                    } label: {
                        Text(topic)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(viewModel.selectedTopic == topic ? Color.blue : Color.gray.opacity(0.2))
                            .foregroundColor(viewModel.selectedTopic == topic ? .white : .primary)
                            .cornerRadius(8)
                    }
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
        .background(Color(UIColor.systemGray6))
    }

    /// Empty state view shown when no articles are available
    var emptyStateView: some View {
        VStack(spacing: 16) {
            Text("RSS Fed")
                .font(.title)
                .padding(.bottom, 8)
            Image("Argus")
                .resizable()
                .scaledToFit()
                .frame(width: 120, height: 120)
                .padding(.bottom, 8)
            VStack(spacing: 16) {
                Text("No news is good news.")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text(getEmptyStateMessage())
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 4)
                
                // Filter information in paragraph form
                Text(getFiltersInfoText())
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                // Subscription information in paragraph form
                if !viewModel.subscriptions.isEmpty {
                    Text(getSubscriptionsInfoText())
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                        .padding(.bottom, 4)
                }
            }
            .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .padding()
    }
    
    // Helper to get active subscriptions for the empty state view
    private func getActiveSubscriptions() -> [String] {
        return viewModel.subscriptions
            .filter { $0.value.isSubscribed }
            .map { $0.key }
            .sorted()
    }
    
    // Helper to create subscription info paragraph
    private func getSubscriptionsInfoText() -> String {
        let activeSubscriptions = getActiveSubscriptions()
        
        if activeSubscriptions.isEmpty {
            return "You don't have any active subscriptions. Visit the Subscriptions tab to subscribe to topics that interest you."
        } else {
            return "You're currently subscribed to: \(activeSubscriptions.joined(separator: ", ")). Articles from these topics will appear here when available."
        }
    }
    
    // Helper to create filters info paragraph
    private func getFiltersInfoText() -> String {
        var activeFilters = [String]()
        
        if viewModel.showUnreadOnly {
            activeFilters.append("Unread Only")
        }
        
        if viewModel.showBookmarkedOnly {
            activeFilters.append("Bookmarked Only")
        }
        
        if viewModel.selectedTopic != "All" {
            activeFilters.append("Topic: \(viewModel.selectedTopic)")
        }
        
        if activeFilters.isEmpty {
            return "No filters are currently active. Pull down to refresh and check for new articles."
        } else {
            return "Active filters: \(activeFilters.joined(separator: ", ")). These filters may be hiding some articles. Try adjusting your filters to see more content."
        }
    }

    // MARK: - Row building

    private struct ArticleContentView: View {
        let article: ArticleModel
        let modelContext: ModelContext
        let filteredArticles: [ArticleModel]
        let totalArticles: [ArticleModel]
        @State private var titleAttributedString: NSAttributedString?
        @State private var bodyAttributedString: NSAttributedString?
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize

        var body: some View {
            // Remove GeometryReader which might be causing sizing issues
            VStack(alignment: .leading, spacing: 8) {
                // Topic pill
                HStack(spacing: 8) {
                    if let topic = article.topic, !topic.isEmpty {
                        TopicPill(topic: topic)
                    }
                    Spacer()
                }

                // Title - with accessibility support
                Group {
                    if let attributedTitle = titleAttributedString {
                        // Remove fixed height constraint
                        AccessibleAttributedText(attributedString: attributedTitle)
                    } else {
                        Text(article.title)
                            .font(.headline)
                            .multilineTextAlignment(.leading)
                    }
                }
                .fontWeight(article.isViewed ? .regular : .bold)

                // Publication Date
                Text(article.publishDate.formatted(.dateTime.month(.abbreviated).day().year().hour().minute()))
                    .font(.footnote)
                    .foregroundColor(.secondary)

                // Body - with accessibility support
                Group {
                    if let attributedBody = bodyAttributedString {
                        // Remove fixed height constraint
                        AccessibleAttributedText(attributedString: attributedBody)
                    } else {
                        Text(article.body)
                            .font(.body)
                            .multilineTextAlignment(.leading)
                            .lineLimit(3)
                    }
                }
                .foregroundColor(.secondary)

                // Affected
                if !article.affected.isEmpty {
                    Text(article.affected)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                }

                // Domain
                if let domain = article.domain, !domain.isEmpty {
                    DomainView(
                        domain: domain,
                        article: article,
                        modelContext: modelContext,
                        filteredArticles: filteredArticles,
                        totalArticles: totalArticles
                    )
                }
            }
            .onAppear {
                loadRichTextContent()
            }
        }

        private func loadRichTextContent() {
            // Use the new markdown utilities to get attributed strings
            titleAttributedString = getAttributedString(
                for: .title,
                from: article,
                createIfMissing: true
            )

            bodyAttributedString = getAttributedString(
                for: .body,
                from: article,
                createIfMissing: true
            )
        }
    }

    private struct DomainView: View {
        let domain: String
        let article: ArticleModel
        let modelContext: ModelContext
        let filteredArticles: [ArticleModel]
        let totalArticles: [ArticleModel]
        @State private var isLoading = false
        @State private var loadError: Error? = nil
        @State private var hasFetchedMetadata = false

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                // Use the shared DomainSourceView component
                DomainSourceView(
                    domain: domain,
                    sourceType: article.sourceType,
                    onTap: {
                        // Only load full content when user taps on the domain
                        if article.sourcesQuality == nil,
                           article.argumentQuality == nil,
                           article.sourceType == nil
                        {
                            loadFullContent()
                        } else {
                            navigateToDetailView(section: "Source Analysis")
                        }
                    },
                    onSourceTap: {
                        navigateToDetailView(section: "Source Analysis")
                    }
                )

                if article.sourcesQuality != nil ||
                    article.argumentQuality != nil ||
                    article.sourceType != nil
                {
                    // Use local data since it's already available
                    QualityBadges(
                        sourcesQuality: article.sourcesQuality,
                        argumentQuality: article.argumentQuality,
                        sourceType: article.sourceType,
                        scrollToSection: .constant(nil),
                        onBadgeTap: { section in
                            navigateToDetailView(section: section)
                        }
                    )
                } else if isLoading {
                    // Show loading indicator
                    ProgressView()
                        .frame(height: 20)
                } else if loadError != nil {
                    // Show error state
                    Text("Failed to load content")
                        .font(.caption)
                        .foregroundColor(.red)
                } else {
                    // No data available yet - just show an empty space
                    // Don't trigger automatic loading
                    Color.clear.frame(height: 20)
                }
            }
            .onAppear {
                // Check if we've already tried to fetch metadata for this article
                if !hasFetchedMetadata &&
                    article.sourcesQuality == nil &&
                    article.argumentQuality == nil &&
                    article.sourceType == nil
                {
                    // Query database for metadata instead of making a network request
                    fetchLocalMetadataOnly()
                }
            }
        }

        private func fetchLocalMetadataOnly() {
            // Mark that we've tried to fetch metadata to avoid repeated attempts
            hasFetchedMetadata = true

            // Only query the local database to see if we have any metadata already stored
            Task {
                // Get a fresh copy of the article to see if it has metadata
                let articleOperations = ArticleOperations()
                if let updatedArticle = await articleOperations.getArticleModelWithContext(byId: article.id) {
                    await MainActor.run {
                        if updatedArticle.sourcesQuality != nil ||
                            updatedArticle.argumentQuality != nil ||
                            updatedArticle.sourceType != nil
                        {
                            // No need to trigger loadFullContent as the database already has the metadata
                            // Just force a view refresh with the latest data
                        }
                    }
                } else {
                    AppLogger.database.error("Could not fetch article \(article.id) for metadata check")
                }
            }
        }

        private func loadFullContent() {
            guard !isLoading else { return }

            isLoading = true

            // Use Task to properly handle async calls
            Task {
                // Access the article with context
                let articleOperations = ArticleOperations()
                if let articleWithContext = await articleOperations.getArticleModelWithContext(byId: article.id) {
                    // Generate rich text content for the fields based on what's currently available
                    _ = articleOperations.getAttributedContent(for: .title, from: articleWithContext, createIfMissing: true)
                    _ = articleOperations.getAttributedContent(for: .body, from: articleWithContext, createIfMissing: true)
                }

                // Update UI state on main thread
                await MainActor.run {
                    isLoading = false
                    loadError = nil
                }
            }
        }

        private func navigateToDetailView(section: String) {
            guard let index = filteredArticles.firstIndex(where: { $0.id == article.id }) else {
                return
            }

            // Create a view model with the appropriate parameters
            let viewModel = NewsDetailViewModel(
                articles: filteredArticles,
                allArticles: totalArticles,
                currentIndex: index,
                initiallyExpandedSection: section
            )

            // We need to make a host view to properly pass the modelContext
            struct DetailViewWrapper: View {
                let viewModel: NewsDetailViewModel
                @Environment(\.modelContext) var modelContext
                
                var body: some View {
                    NewsDetailView(viewModel: viewModel)
                }
            }
            
            let detailView = DetailViewWrapper(viewModel: viewModel)

            let hostingController = UIHostingController(rootView: detailView)
            hostingController.modalPresentationStyle = UIModalPresentationStyle.fullScreen

            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let window = windowScene.windows.first,
               let rootViewController = window.rootViewController
            {
                rootViewController.present(hostingController, animated: true)
            }
        }
    }

    private func ArticleRow(
        article: ArticleModel,
        editMode: Binding<EditMode>?,
        selectedArticleIDs: Binding<Set<ArticleModel.ID>>
    ) -> some View {
        // Create a local state to track the animation
        let isUnread = !article.isViewed

        return VStack(alignment: .leading, spacing: 10) {
            // Top row
            headerRow(article)

            // Title
            titleView(article)

            // Publication Date
            publicationDateView(article)

            // Summary
            summaryContent(article)

            // Affected Field
            affectedFieldView(article)

            // Domain
            domainView(article)

            // Quality Badges
            badgesView(article)
        }
        .padding()
        .background(isUnread ? Color.blue.opacity(0.15) : Color.clear)
        .cornerRadius(10)
        .id(article.id)
        .onLongPressGesture {
            withAnimation {
                editMode?.wrappedValue = .active
                selectedArticleIDs.wrappedValue.insert(article.id)
            }
        }
        // Single tap gesture to open article
        .onTapGesture {
            openArticle(article)
        }
        // Double tap gesture to toggle read status
        .onTapGesture(count: 2) {
            toggleReadStatus(article)
        }
        .onAppear {
            loadMoreArticlesIfNeeded(currentItem: article)

            // If the blob doesn't exist yet, generate and save it
            Task {
                await viewModel.generateBodyBlobIfNeeded(articleID: article.id)
            }
        }
    }

    // Helper functions for each part of the row
    private func headerRow(_ article: ArticleModel) -> some View {
        HStack(spacing: 8) {
            if let topic = article.topic, !topic.isEmpty {
                TopicPill(topic: topic)
            }
            Spacer()
            BookmarkButton(article: article)
        }
    }

    private func titleView(_ article: ArticleModel) -> some View {
        Text(article.title)
            .font(.headline)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.disabled)
    }

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private func publicationDateView(_ article: ArticleModel) -> some View {
        Group {
            Text(dateFormatter.string(from: article.publishDate))
                .font(.footnote)
                .foregroundColor(.secondary)
                .textSelection(.disabled)
        }
    }

    // Summary content from extensions
    private func summaryContent(_ article: ArticleModel) -> some View {
        Group {
            if !article.body.isEmpty {
                if let bodyBlobData = article.bodyBlob,
                   let attributedString = try? NSKeyedUnarchiver.unarchivedObject(
                       ofClass: NSAttributedString.self,
                       from: bodyBlobData
                   )
                {
                    // Use NonSelectableRichTextView to match NewsDetailView's rendering
                    NonSelectableRichTextView(attributedString: attributedString)
                        .foregroundColor(.secondary)
                        .padding(.top, 5)
                        .textSelection(.disabled)
                } else {
                    // Fallback to plain text with original styling
                    Text(article.body)
                        .font(.subheadline) // Keep the original font size
                        .foregroundColor(.secondary) // Keep the original color
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 5)
                        .textSelection(.disabled)
                }
            }
        }
    }

    // Affected field from extensions
    private func affectedFieldView(_ article: ArticleModel) -> some View {
        Group {
            if !article.affected.isEmpty {
                Text(article.affected)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .padding(.top, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.disabled)
            }
        }
    }

    private func domainView(_ article: ArticleModel) -> some View {
        Group {
            if let domain = article.domain, !domain.isEmpty {
                DomainSourceView(
                    domain: domain,
                    sourceType: article.sourceType,
                    onTap: {
                        // We'll just use the default tap behavior here like before
                        openArticle(article)
                    },
                    onSourceTap: {
                        // Also open the article when source type is tapped
                        openArticle(article)
                    }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 3)
                .textSelection(.disabled)
            }
        }
    }

    private func badgesView(_ article: ArticleModel) -> some View {
        HStack {
            // Show quality badges directly
            QualityBadges(
                sourcesQuality: article.sourcesQuality,
                argumentQuality: article.argumentQuality,
                sourceType: article.sourceType,
                scrollToSection: .constant(nil),
                onBadgeTap: { _ in
                    openArticle(article)
                }
            )
        }
        .padding(.top, 5)
    }

    private func handleScrollBegin() {
        isActivelyScrolling = true

        // Cancel any existing timer
        scrollIdleTimer?.cancel()

        // Create a new timer for when scrolling stops
        scrollIdleTimer = Task {
            // Wait for scroll to be idle (1 second)
            try? await Task.sleep(nanoseconds: 1 * 1_000_000_000)

            await MainActor.run {
                isActivelyScrolling = false

                // If there's a pending update, run it now
                if viewModel.pendingUpdateNeeded {
                    Task {
                        await viewModel.refreshArticles()
                    }
                }
            }
        }
    }

    // Simplified bookmark icon on the trailing side
    private func BookmarkButton(article: ArticleModel) -> some View {
        Button {
            toggleBookmark(article)
        } label: {
            Image(systemName: article.isBookmarked ? "bookmark.fill" : "bookmark")
                .foregroundColor(article.isBookmarked ? .blue : .gray)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Toolbar and Filter Sheet

    var filterSheet: some View {
        VStack(spacing: 0) {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation {
                        isFilterViewPresented = false
                    }
                }
            FilterView(
                showUnreadOnly: Binding(
                    get: { viewModel.showUnreadOnly },
                    set: { viewModel.showUnreadOnly = $0 }
                ),
                showBookmarkedOnly: Binding(
                    get: { viewModel.showBookmarkedOnly },
                    set: { viewModel.showBookmarkedOnly = $0 }
                ),
                onFilterChanged: {
                    Task {
                        await viewModel.applyFilters(
                            showUnreadOnly: viewModel.showUnreadOnly,
                            showBookmarkedOnly: viewModel.showBookmarkedOnly
                        )
                    }
                }
            )
            .frame(height: filterViewHeight)
            .background(Color(UIColor.systemBackground))
            .cornerRadius(15, corners: UIRectCorner([.topLeft, .topRight]))
            .shadow(radius: 10)
            .gesture(
                DragGesture()
                    .onEnded { value in
                        if value.translation.height > 50 {
                            withAnimation {
                                isFilterViewPresented = false
                            }
                        }
                    }
            )
        }
        .transition(.move(edge: .bottom))
        .ignoresSafeArea()
        .padding(.bottom, tabBarHeight)
    }

    var editToolbar: some View {
        HStack {
            toolbarButton(
                icon: "envelope.badge",
                label: "Toggle Read"
            ) {
                self.performActionOnSelection { toggleReadStatus($0) }
            }
            Spacer()
            toolbarButton(
                icon: "bookmark",
                label: "Bookmark"
            ) {
                self.performActionOnSelection { toggleBookmark($0) }
            }
            Spacer()
            toolbarButton(
                icon: "trash",
                label: "Delete",
                isDestructive: true
            ) {
                handleEditModeDelete()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color(UIColor.systemBackground))
        .cornerRadius(15, corners: UIRectCorner([.topLeft, .topRight]))
        .shadow(radius: 10)
    }

    private func toolbarButton(
        icon: String,
        label: String,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                Text(label)
                    .font(.system(size: 10))
            }
            .foregroundColor(isDestructive ? .red : .primary)
            .frame(minWidth: 60)
        }
    }

    private func customEditButton() -> some View {
        Button(action: {
            withAnimation {
                if editMode?.wrappedValue == .inactive {
                    editMode?.wrappedValue = .active
                } else {
                    editMode?.wrappedValue = .inactive
                    viewModel.selectedArticleIds.removeAll()
                }
            }
        }) {
            Text(editMode?.wrappedValue == .active ? "Cancel" : "Edit")
        }
    }

    // MARK: - Logic / Helpers

    private func handleTapGesture(for article: ArticleModel) {
        // If in Edit mode, toggle selection
        if editMode?.wrappedValue == .active {
            withAnimation {
                if viewModel.selectedArticleIds.contains(article.id) {
                    viewModel.selectedArticleIds.remove(article.id)
                } else {
                    viewModel.selectedArticleIds.insert(article.id)
                }
            }
        } else {
            // Otherwise, open article
            openArticle(article)
        }
    }

    private func handleLongPressGesture(for article: ArticleModel) {
        // Long-press triggers Edit mode and selects the row
        withAnimation {
            if editMode?.wrappedValue == .inactive {
                editMode?.wrappedValue = .active
                viewModel.selectedArticleIds.insert(article.id)
            }
        }
    }

    private func handleEditModeDelete() {
        if !viewModel.selectedArticleIds.isEmpty {
            // If user is deleting multiple selected rows
            articleToDelete = nil
            showDeleteConfirmation = true
        }
    }

    private func deleteArticle(_ article: ArticleModel) {
        Task {
            await viewModel.deleteArticle(article)

            // Update app badge count
            NotificationUtils.updateAppBadgeCount()

            // Clear selection
            viewModel.selectedArticleIds.removeAll()
        }
    }

    private func deleteSelectedArticles() {
        withAnimation {
            Task {
                await viewModel.performBatchOperation(.delete)
            }
            editMode?.wrappedValue = .inactive
            // The selectedArticleIds are cleared in the ViewModel's performBatchOperation
        }
    }
    
    
    // MARK: - Filter View
    
    private struct FilterView: View {
        @Binding var showUnreadOnly: Bool
        @Binding var showBookmarkedOnly: Bool
        var onFilterChanged: () -> Void
        
        var body: some View {
            VStack(alignment: .leading, spacing: 20) {
                Text("Filter Articles")
                    .font(.headline)
                    .padding(.top, 10)
                
                VStack(alignment: .leading, spacing: 16) {
                    Toggle(isOn: $showUnreadOnly) {
                        Label("Unread Only", systemImage: "envelope.badge")
                    }
                    .onChange(of: showUnreadOnly) { _, _ in
                        onFilterChanged()
                    }
                    
                    Toggle(isOn: $showBookmarkedOnly) {
                        Label("Bookmarked Only", systemImage: "bookmark.fill")
                    }
                    .onChange(of: showBookmarkedOnly) { _, _ in
                        onFilterChanged()
                    }
                }
                
                Text("Changes are applied immediately")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 10)
                
                Spacer()
            }
            .padding(.horizontal, 20)
        }
    }
    
    // MARK: - Article Operations
    
    private func toggleReadStatus(_ article: ArticleModel) {
        Task {
            await viewModel.toggleReadStatus(for: article)
        }
    }
    
    private func toggleBookmark(_ article: ArticleModel) {
        Task {
            await viewModel.toggleBookmark(for: article)
        }
    }
    
    // Helper functions that existed in the original code
}
