import Foundation
import SwiftData
import SwiftUI

/// Diagnostic tool for blob handling in the Argus app
@MainActor
class BlobDiagnosticTool {
    private let articleService: ArticleService
    private let articleOperations: ArticleOperations

    init() {
        articleService = ArticleService.shared
        articleOperations = ArticleOperations()
    }

    /// Run comprehensive diagnostics on blob storage and retrieval
    func runDiagnostics() async -> String {
        var report = "# Blob Storage Diagnostic Report\n\n"

        // Step 1: Find a recent article with rich text content
        report += "## Step 1: Looking for test articles\n"

        let fetchDescriptor = FetchDescriptor<ArticleModel>()
        let context = ModelContext(SwiftDataContainer.shared.container)

        do {
            let articles = try context.fetch(fetchDescriptor)
            report += "Found \(articles.count) articles in database\n"

            guard !articles.isEmpty else {
                return report + "❌ ERROR: No articles in database to test"
            }

            // Select an article for testing
            let testArticle = articles[0]
            report += "Selected article \(testArticle.id) for testing\n\n"

            // Step 2: Analyze current blob state
            report += "## Step 2: Initial blob state of article \(testArticle.id)\n"
            report += "- Title blob: \(testArticle.titleBlob != nil ? "Present (\(testArticle.titleBlob?.count ?? 0) bytes)" : "Missing")\n"
            report += "- Body blob: \(testArticle.bodyBlob != nil ? "Present (\(testArticle.bodyBlob?.count ?? 0) bytes)" : "Missing")\n"
            report += "- Summary blob: \(testArticle.summaryBlob != nil ? "Present (\(testArticle.summaryBlob?.count ?? 0) bytes)" : "Missing")\n\n"

            // Step 3: Get NotificationData and verify blob transfer
            report += "## Step 3: Converting to NotificationData\n"
            let notification = NotificationData.from(articleModel: testArticle)
            report += "- NotificationData created with ID: \(notification.id)\n"
            report += "- Title blob transferred: \(notification.title_blob != nil ? "Yes (\(notification.title_blob?.count ?? 0) bytes)" : "No")\n"
            report += "- Body blob transferred: \(notification.body_blob != nil ? "Yes (\(notification.body_blob?.count ?? 0) bytes)" : "No")\n"
            report += "- Summary blob transferred: \(notification.summary_blob != nil ? "Yes (\(notification.summary_blob?.count ?? 0) bytes)" : "No")\n"
            report += "- Model context present: \(notification.modelContext != nil ? "Yes" : "No")\n\n"

            // Step 4: Test ArticleOperations.getArticleModelWithContext
            report += "## Step 4: Testing getArticleModelWithContext\n"
            if let model = await articleOperations.getArticleModelWithContext(byId: testArticle.id) {
                report += "✅ Successfully retrieved ArticleModel with context\n"
                report += "- Model context present: \(model.modelContext != nil ? "Yes" : "No")\n\n"
            } else {
                report += "❌ Failed to retrieve ArticleModel with context\n\n"
            }

            // Step 5: Test blob generation and saving
            report += "## Step 5: Testing rich text generation and blob saving\n"
            if notification.summary == nil || notification.summary?.isEmpty == true {
                report += "Summary not available for testing blob generation\n"
            } else {
                // Generate rich text for summary if it doesn't exist
                if notification.summary_blob == nil {
                    report += "Summary blob missing, generating now...\n"

                    // Get an ArticleModel with context
                    if let model = await articleOperations.getArticleModelWithContext(byId: testArticle.id) {
                        // Generate the rich text
                        if let summaryText = notification.summary,
                           let attrString = markdownToAttributedString(summaryText, textStyle: "UIFontTextStyleBody")
                        {
                            // Create blob data
                            do {
                                let blobData = try NSKeyedArchiver.archivedData(
                                    withRootObject: attrString,
                                    requiringSecureCoding: false
                                )

                                // Save blob to the ArticleModel directly
                                let success = articleOperations.saveBlobToDatabase(
                                    field: .summary,
                                    blobData: blobData,
                                    articleModel: model
                                )

                                report += success ?
                                    "✅ Successfully generated and saved summary blob to ArticleModel (\(blobData.count) bytes)\n" :
                                    "❌ Failed to save generated summary blob to ArticleModel\n"
                            } catch {
                                report += "❌ Error creating blob data: \(error)\n"
                            }
                        } else {
                            report += "❌ Failed to generate attributed string from summary text\n"
                        }
                    } else {
                        report += "❌ Could not get ArticleModel with context for blob saving\n"
                    }
                } else {
                    report += "Summary blob already exists, skipping generation\n"
                }
            }

            // Step 6: Re-fetch the article and verify blob was saved
            report += "\n## Step 6: Verifying blob persistence\n"

            // Fetch fresh article to verify the blob was saved to database
            let refreshDescriptor = FetchDescriptor<ArticleModel>(
                predicate: #Predicate<ArticleModel> { $0.id == testArticle.id }
            )

            if let refreshedArticle = try context.fetch(refreshDescriptor).first {
                report += "Successfully re-fetched ArticleModel\n"
                report += "- Summary blob: \(refreshedArticle.summaryBlob != nil ? "Present (\(refreshedArticle.summaryBlob?.count ?? 0) bytes)" : "Missing")\n"

                // Test blob validity
                if let summaryBlob = refreshedArticle.summaryBlob {
                    do {
                        let _ = try NSKeyedUnarchiver.unarchivedObject(
                            ofClass: NSAttributedString.self,
                            from: summaryBlob
                        )
                        report += "✅ Summary blob is valid and can be unarchived\n"
                    } catch {
                        report += "❌ Failed to unarchive summary blob: \(error)\n"
                    }
                }
            } else {
                report += "❌ Failed to re-fetch ArticleModel\n"
            }

            report += "\n## Diagnostic Summary\n"
            report += "The diagnostic test ran all steps of the blob processing pipeline, showing where the rich text blobs are generated, transferred between models, and saved to the database. If all steps show success, this confirms the fix is properly implemented."

            return report

        } catch {
            return report + "❌ ERROR: \(error)"
        }
    }
}
