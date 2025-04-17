import SwiftUI
import SwiftData

/// A test view to preview the enhanced related articles interface
struct RelatedArticlesTestView: View {
    @State private var articles: [RelatedArticle] = [
        // Create a sample article with all the new vector and entity similarity data
        RelatedArticle(
            id: 1,
            category: "Technology",
            jsonURL: "https://example.com/article1.json",
            publishedDate: Date(),
            qualityScore: 4,
            similarityScore: 0.98,
            tinySummary: "This is a test article with very high similarity scores across multiple dimensions",
            title: "AI makes breakthrough in quantum computing research",
            
            // Vector quality fields
            vectorScore: 0.95,
            vectorActiveDimensions: 768,
            vectorMagnitude: 1.25,
            
            // Entity similarity fields
            entityOverlapCount: 12,
            primaryOverlapCount: 5,
            personOverlap: 0.87,
            orgOverlap: 0.75,
            locationOverlap: 0.32,
            eventOverlap: 0.90,
            temporalProximity: 0.98,
            
            // Formula explanation
            similarityFormula: "60% vector similarity (0.95) + 40% entity similarity (0.82), where entity similarity combines person (30%), organization (20%), location (15%), event (15%), and temporal (20%) factors"
        ),
        // Another sample with medium similarity
        RelatedArticle(
            id: 2,
            category: "Science",
            jsonURL: "https://example.com/article2.json",
            publishedDate: Date().addingTimeInterval(-86400), // Yesterday
            qualityScore: 3,
            similarityScore: 0.75,
            tinySummary: "This article has medium similarity with interesting entity overlaps in organizations",
            title: "Research institute announces quantum computing initiative",
            
            // Vector quality fields
            vectorScore: 0.68,
            vectorActiveDimensions: 768,
            vectorMagnitude: 1.15,
            
            // Entity similarity fields
            entityOverlapCount: 8,
            primaryOverlapCount: 3,
            personOverlap: 0.45,
            orgOverlap: 0.92,
            locationOverlap: 0.22,
            eventOverlap: 0.35,
            temporalProximity: 0.65,
            
            // Formula explanation
            similarityFormula: "60% vector similarity (0.68) + 40% entity similarity (0.72), where entity similarity combines person (30%), organization (20%), location (15%), event (15%), and temporal (20%) factors"
        ),
        // An article with lower similarity
        RelatedArticle(
            id: 3,
            category: "Business",
            jsonURL: "https://example.com/article3.json",
            publishedDate: Date().addingTimeInterval(-172800), // Two days ago
            qualityScore: 2,
            similarityScore: 0.60,
            tinySummary: "This article shares only a few entities but has temporal proximity",
            title: "Tech company announces financial results",
            
            // Vector quality fields
            vectorScore: 0.55,
            vectorActiveDimensions: 768,
            vectorMagnitude: 1.05,
            
            // Entity similarity fields
            entityOverlapCount: 4,
            primaryOverlapCount: 1,
            personOverlap: 0.25,
            orgOverlap: 0.60,
            locationOverlap: 0.10,
            eventOverlap: 0.15,
            temporalProximity: 0.85,
            
            // Formula explanation
            similarityFormula: "60% vector similarity (0.55) + 40% entity similarity (0.48), where entity similarity combines person (30%), organization (20%), location (15%), event (15%), and temporal (20%) factors"
        )
    ]
    
    var body: some View {
        VStack {
            Text("Enhanced Related Articles")
                .font(.largeTitle)
                .padding(.top, 20)
            
            Divider()
            
            EnhancedRelatedArticlesView(articles: articles) { jsonURL in
                print("Selected article with URL: \(jsonURL)")
            }
            .padding()
        }
    }
}

#Preview {
    RelatedArticlesTestView()
}
