import SwiftUI

// MARK: - Main Components

/// Displays an expandable row for a related article with progressive disclosure
struct EnhancedRelatedArticleRow: View {
    let article: RelatedArticle
    var onSelect: (String) -> Void
    
    @State private var isExpanded = false
    @State private var showVectorDetails = false
    @State private var showEntityDetails = false
    @State private var showFormulaDetails = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Main content (always visible)
            Button(action: {
                if !article.jsonURL.isEmpty {
                    onSelect(article.jsonURL)
                }
            }) {
                HStack(spacing: 4) {
                    Text(article.title)
                        .font(.headline)
                        .foregroundColor(.blue)
                        .multilineTextAlignment(.leading)
                    
                    Spacer(minLength: 8)
                    
                    SimilarityBadge(similarity: article.similarityScore)
                }
            }
            
            // Date & Category
            HStack {
                if !article.formattedDate.isEmpty {
                    Text(article.formattedDate)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if !article.category.isEmpty {
                    Text(article.category.uppercased())
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.gray.opacity(0.6))
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
            }
            
            // Summary
            if !article.tinySummary.isEmpty {
                Text(article.tinySummary)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .lineLimit(isExpanded ? nil : 2)
                    .padding(.bottom, 4)
            }
            
            // Quality score
            if article.qualityScore > 0 {
                Text("Quality: \(article.qualityDescription)")
                    .font(.caption)
                    .foregroundColor(.primary)
            }
            
            // Expand/collapse button
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }) {
                HStack {
                    Text(isExpanded ? "Hide details" : "Show similarity details")
                        .font(.caption)
                        .foregroundColor(.blue)
                    
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
                .padding(.vertical, 4)
            }
            
            // Expandable details
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    // Vector similarity section
                    DisclosureGroup(
                        isExpanded: $showVectorDetails,
                        content: {
                            VectorDetailsView(article: article)
                        },
                        label: {
                            Text("Vector Similarity")
                                .font(.subheadline)
                                .fontWeight(.medium)
                        }
                    )
                    .padding(.vertical, 4)
                    
                    // Entity similarity section (only if we have entity data)
                    if article.hasEntityData {
                        DisclosureGroup(
                            isExpanded: $showEntityDetails,
                            content: {
                                EntityDetailsView(article: article)
                            },
                            label: {
                                Text("Entity Similarity")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                            }
                        )
                        .padding(.vertical, 4)
                    }
                    
                    // Formula explanation section (only if available)
                    if let formula = article.similarityFormula, !formula.isEmpty {
                        DisclosureGroup(
                            isExpanded: $showFormulaDetails,
                            content: {
                                FormulaExplanationView(formula: formula)
                            },
                            label: {
                                Text("Similarity Formula")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                            }
                        )
                        .padding(.vertical, 4)
                    }
                }
                .padding(8)
                .background(Color(UIColor.systemGray6))
                .cornerRadius(8)
            }
        }
        .padding(12)
        .background(Color(UIColor.systemGray5).opacity(0.5))
        .cornerRadius(12)
    }
}

/// Visual representation of similarity as a colored badge
struct SimilarityBadge: View {
    let similarity: Double
    
    var body: some View {
        Text("\(Int(similarity * 100))%")
            .font(.caption)
            .fontWeight(.bold)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(similarityColor)
            .foregroundColor(.white)
            .cornerRadius(8)
    }
    
    private var similarityColor: Color {
        if similarity >= 0.98 {
            return .red      // Extremely high similarity
        } else if similarity >= 0.95 {
            return .orange   // Very high similarity
        } else if similarity >= 0.85 {
            return .blue     // High similarity
        } else {
            return .gray     // Moderate similarity
        }
    }
}

/// Visual component showing a metric with a value and bar
struct MetricBarView: View {
    let label: String
    let value: Double?
    let icon: String?
    let tooltipText: String?
    let color: Color
    
    init(label: String, value: Double?, icon: String? = nil, tooltipText: String? = nil, color: Color = .blue) {
        self.label = label
        self.value = value
        self.icon = icon
        self.tooltipText = tooltipText
        self.color = color
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Label with icon and tooltip
            HStack(alignment: .center, spacing: 4) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundColor(color)
                }
                
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                if let tooltipText = tooltipText {
                    InfoTooltip(message: tooltipText)
                }
                
                Spacer()
                
                if let value = value {
                    Text("\(Int(value * 100))%")
                        .font(.caption)
                        .foregroundColor(.primary)
                } else {
                    Text("N/A")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            // Bar
            if let value = value {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        // Background
                        Rectangle()
                            .frame(width: geometry.size.width, height: 6)
                            .foregroundColor(Color.gray.opacity(0.3))
                            .cornerRadius(3)
                        
                        // Value
                        Rectangle()
                            .frame(width: geometry.size.width * CGFloat(value), height: 6)
                            .foregroundColor(color)
                            .cornerRadius(3)
                    }
                }
                .frame(height: 6)
            } else {
                Rectangle()
                    .frame(height: 6)
                    .foregroundColor(Color.gray.opacity(0.3))
                    .cornerRadius(3)
            }
        }
    }
}

/// A tooltip with informational content
struct InfoTooltip: View {
    let message: String
    @State private var showTooltip = false
    
    var body: some View {
        Button(action: {
            withAnimation {
                showTooltip.toggle()
            }
        }) {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundColor(.blue)
        }
        .popover(isPresented: $showTooltip) {
            Text(message)
                .font(.caption)
                .padding(8)
                .presentationCompactAdaptation(.popover)
        }
    }
}

// MARK: - Detail Views

/// Displays vector similarity details
struct VectorDetailsView: View {
    let article: RelatedArticle
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Vector Score
            MetricBarView(
                label: "Vector Similarity",
                value: article.vectorScore,
                icon: "waveform.path",
                tooltipText: "The raw vector similarity score (cosine similarity) before any weighting is applied.",
                color: .purple
            )
            
            // Vector Properties
            HStack(spacing: 12) {
                // Dimensions
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Dimensions:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        InfoTooltip(message: "The number of dimensions in the embedding vector that contribute to similarity calculation.")
                    }
                    
                    Text(article.formattedVectorDimensions ?? "N/A")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                
                // Magnitude
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Magnitude:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        InfoTooltip(message: "The L2 norm (length) of the article's embedding vector. Indicates the 'strength' of the vector representation.")
                    }
                    
                    Text(article.formattedVectorMagnitude ?? "N/A")
                        .font(.caption)
                        .fontWeight(.medium)
                }
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 8)
    }
}

/// Displays entity similarity details
struct EntityDetailsView: View {
    let article: RelatedArticle
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Entity Counts
            HStack(spacing: 12) {
                // Total Entities
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Total Entities:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        InfoTooltip(message: "The total number of entities (people, organizations, locations, events) that appear in both articles.")
                    }
                    
                    Text(article.formattedEntityOverlapCount ?? "N/A")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                
                // Primary Entities
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Primary Entities:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        InfoTooltip(message: "The number of PRIMARY importance entities that appear in both articles. These are main subjects and have greater weight.")
                    }
                    
                    Text(article.formattedPrimaryOverlapCount ?? "N/A")
                        .font(.caption)
                        .fontWeight(.medium)
                }
            }
            .padding(.bottom, 4)
            
            // Person Overlap
            MetricBarView(
                label: "Person Overlap",
                value: article.personOverlap,
                icon: "person.fill",
                tooltipText: "Similarity based on people mentioned in both articles.",
                color: .blue
            )
            
            // Organization Overlap
            MetricBarView(
                label: "Organization Overlap",
                value: article.orgOverlap,
                icon: "building.2.fill",
                tooltipText: "Similarity based on organizations mentioned in both articles.",
                color: .orange
            )
            
            // Location Overlap
            MetricBarView(
                label: "Location Overlap",
                value: article.locationOverlap,
                icon: "mappin.circle.fill",
                tooltipText: "Similarity based on locations mentioned in both articles.",
                color: .green
            )
            
            // Event Overlap
            MetricBarView(
                label: "Event Overlap",
                value: article.eventOverlap,
                icon: "calendar",
                tooltipText: "Similarity based on events mentioned in both articles.",
                color: .pink
            )
            
            // Temporal Proximity
            MetricBarView(
                label: "Temporal Proximity",
                value: article.temporalProximity,
                icon: "clock.fill",
                tooltipText: "Similarity based on how close the articles' event dates are to each other.",
                color: .teal
            )
        }
        .padding(.top, 4)
        .padding(.bottom, 8)
    }
}

/// Displays the similarity formula explanation
struct FormulaExplanationView: View {
    let formula: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Title
            Text("How the similarity score was calculated:")
                .font(.caption)
                .foregroundColor(.secondary)
            
            // Formula
            Text(formula)
                .font(.caption)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(UIColor.systemGray6))
                .cornerRadius(8)
            
            // Help text
            Text("This formula combines vector similarity (based on content meaning) with entity similarity (based on shared named entities) to determine how closely related the articles are.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.top, 4)
        }
        .padding(.top, 4)
        .padding(.bottom, 8)
    }
}

/// Main view for displaying related articles
struct EnhancedRelatedArticlesView: View {
    let articles: [RelatedArticle]
    let onArticleSelected: (String) -> Void
    
    @State private var showError = false
    @State private var errorMessage = "Sorry, this article doesn't exist."
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header and explanation
            HStack {
                Text("Related Articles")
                    .font(.headline)
                    .padding(.bottom, 4)
                
                Spacer()
                
                InfoTooltip(message: "Articles that are related to this one based on content similarity, shared entities (people, organizations, locations), and temporal proximity.")
            }
            
            // Articles list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(articles) { article in
                        EnhancedRelatedArticleRow(article: article) { jsonURL in
                            if !jsonURL.isEmpty {
                                AppLogger.database.debug("Selected related article: ID: \(article.id), URL: \(jsonURL)")
                                onArticleSelected(jsonURL)
                            } else {
                                errorMessage = "This related article has an empty URL and cannot be opened."
                                showError = true
                                AppLogger.database.error("Related article has empty URL: ID: \(article.id), Title: \(article.title)")
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 500)
            
            // Diagnostic info
            Text("Found \(articles.count) related articles")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 4)
        }
        .alert(errorMessage, isPresented: $showError) {
            Button("OK", role: .cancel) {}
        }
        .onAppear {
            // Log the related articles for debugging
            AppLogger.database.debug("EnhancedRelatedArticlesView displaying \(articles.count) articles")
            for (index, article) in articles.enumerated() {
                AppLogger.database.debug("Article \(index + 1): ID \(article.id), Title: \(article.title), URL: \(article.jsonURL.isEmpty ? "EMPTY" : article.jsonURL)")
            }
        }
    }
}
