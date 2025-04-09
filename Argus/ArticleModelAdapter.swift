import Foundation
import SwiftData
import SwiftUI

/// Provides conversion methods between ArticleModel and NotificationData
/// including enhanced blob handling
extension NotificationData {
    /// Creates a NotificationData object from an ArticleModel with blob validation
    /// This allows the UI layer to continue working with NotificationData while
    /// the data layer works with the new ArticleModel
    static func from(articleModel: ArticleModel) -> NotificationData {
        AppLogger.database.debug("🔄 Converting ArticleModel to NotificationData: \(articleModel.id)")

        // Validate blobs before conversion
        let validatedBlobs = validateBlobs(articleModel)

        let notification = NotificationData(
            id: articleModel.id,
            date: articleModel.addedDate,
            title: articleModel.title,
            body: articleModel.body,
            json_url: articleModel.jsonURL,
            article_url: articleModel.url ?? "",
            topic: articleModel.topic,
            article_title: articleModel.articleTitle,
            affected: articleModel.affected,
            domain: articleModel.domain ?? "",
            pub_date: articleModel.publishDate,
            isViewed: articleModel.isViewed,
            isBookmarked: articleModel.isBookmarked,
            isArchived: false, // Archive functionality removed - always false
            sources_quality: articleModel.sourcesQuality,
            argument_quality: articleModel.argumentQuality,
            source_type: articleModel.sourceType,
            source_analysis: articleModel.sourceAnalysis,
            quality: articleModel.quality,
            summary: articleModel.summary,
            critical_analysis: articleModel.criticalAnalysis,
            logical_fallacies: articleModel.logicalFallacies,
            relation_to_topic: articleModel.relationToTopic,
            additional_insights: articleModel.additionalInsights,
            title_blob: validatedBlobs.titleBlob,
            body_blob: validatedBlobs.bodyBlob,
            summary_blob: validatedBlobs.summaryBlob,
            critical_analysis_blob: validatedBlobs.criticalAnalysisBlob,
            logical_fallacies_blob: validatedBlobs.logicalFallaciesBlob,
            source_analysis_blob: validatedBlobs.sourceAnalysisBlob,
            relation_to_topic_blob: validatedBlobs.relationToTopicBlob,
            additional_insights_blob: validatedBlobs.additionalInsightsBlob,
            engine_stats: articleModel.engineStats,
            similar_articles: articleModel.similarArticles
        )

        AppLogger.database.debug("✅ Conversion complete with \(validatedBlobs.blobCount) valid blobs")
        return notification
    }

    /// Validates blobs from an ArticleModel to ensure they're valid
    /// Returns a tuple with validated blobs and blob count
    private static func validateBlobs(_ articleModel: ArticleModel) -> (
        titleBlob: Data?,
        bodyBlob: Data?,
        summaryBlob: Data?,
        criticalAnalysisBlob: Data?,
        logicalFallaciesBlob: Data?,
        sourceAnalysisBlob: Data?,
        relationToTopicBlob: Data?,
        additionalInsightsBlob: Data?,
        blobCount: Int
    ) {
        var blobCount = 0
        var titleBlob: Data?
        var bodyBlob: Data?
        var summaryBlob: Data?
        var criticalAnalysisBlob: Data?
        var logicalFallaciesBlob: Data?
        var sourceAnalysisBlob: Data?
        var relationToTopicBlob: Data?
        var additionalInsightsBlob: Data?

        // Helper function to validate a single blob
        func validateBlob(_ blob: Data?, name: String) -> Data? {
            guard let blob = blob, !blob.isEmpty else {
                return nil
            }

            do {
                if let _ = try NSKeyedUnarchiver.unarchivedObject(
                    ofClass: NSAttributedString.self,
                    from: blob
                ) {
                    blobCount += 1
                    AppLogger.database.debug("✅ Valid \(name) blob: \(blob.count) bytes")
                    return blob
                } else {
                    AppLogger.database.warning("⚠️ \(name) blob unarchived to nil")
                    return nil
                }
            } catch {
                AppLogger.database.error("❌ Invalid \(name) blob: \(error.localizedDescription)")
                return nil
            }
        }

        // Validate each blob
        titleBlob = validateBlob(articleModel.titleBlob, name: "title")
        bodyBlob = validateBlob(articleModel.bodyBlob, name: "body")
        summaryBlob = validateBlob(articleModel.summaryBlob, name: "summary")
        criticalAnalysisBlob = validateBlob(articleModel.criticalAnalysisBlob, name: "critical_analysis")
        logicalFallaciesBlob = validateBlob(articleModel.logicalFallaciesBlob, name: "logical_fallacies")
        sourceAnalysisBlob = validateBlob(articleModel.sourceAnalysisBlob, name: "source_analysis")
        relationToTopicBlob = validateBlob(articleModel.relationToTopicBlob, name: "relation_to_topic")
        additionalInsightsBlob = validateBlob(articleModel.additionalInsightsBlob, name: "additional_insights")

        return (
            titleBlob: titleBlob,
            bodyBlob: bodyBlob,
            summaryBlob: summaryBlob,
            criticalAnalysisBlob: criticalAnalysisBlob,
            logicalFallaciesBlob: logicalFallaciesBlob,
            sourceAnalysisBlob: sourceAnalysisBlob,
            relationToTopicBlob: relationToTopicBlob,
            additionalInsightsBlob: additionalInsightsBlob,
            blobCount: blobCount
        )
    }
}

/// Extension to update ArticleModel blobs from NotificationData
extension ArticleModel {
    /// Updates blob data from a NotificationData object with validation
    func updateBlobs(from notification: NotificationData) {
        AppLogger.database.debug("🔄 Updating blobs for ArticleModel \(id) from NotificationData")

        // Helper function to validate and update a blob
        func validateAndUpdateBlob(sourceBlob: Data?, name: String) -> Data? {
            guard let blob = sourceBlob, !blob.isEmpty else {
                AppLogger.database.debug("⚠️ No \(name) blob to transfer")
                return nil
            }

            do {
                if let _ = try NSKeyedUnarchiver.unarchivedObject(
                    ofClass: NSAttributedString.self,
                    from: blob
                ) {
                    AppLogger.database.debug("✅ Transferred valid \(name) blob: \(blob.count) bytes")
                    return blob
                } else {
                    AppLogger.database.warning("⚠️ \(name) blob unarchived to nil, skipping transfer")
                    return nil
                }
            } catch {
                AppLogger.database.error("❌ Invalid \(name) blob: \(error.localizedDescription), skipping transfer")
                return nil
            }
        }

        // Update each blob with validation
        titleBlob = validateAndUpdateBlob(sourceBlob: notification.title_blob, name: "title")
        bodyBlob = validateAndUpdateBlob(sourceBlob: notification.body_blob, name: "body")
        summaryBlob = validateAndUpdateBlob(sourceBlob: notification.summary_blob, name: "summary")
        criticalAnalysisBlob = validateAndUpdateBlob(sourceBlob: notification.critical_analysis_blob, name: "criticalAnalysis")
        logicalFallaciesBlob = validateAndUpdateBlob(sourceBlob: notification.logical_fallacies_blob, name: "logicalFallacies")
        sourceAnalysisBlob = validateAndUpdateBlob(sourceBlob: notification.source_analysis_blob, name: "sourceAnalysis")
        relationToTopicBlob = validateAndUpdateBlob(sourceBlob: notification.relation_to_topic_blob, name: "relationToTopic")
        additionalInsightsBlob = validateAndUpdateBlob(sourceBlob: notification.additional_insights_blob, name: "additionalInsights")

        // Update the engine stats and similar articles fields too
        engineStats = notification.engine_stats
        similarArticles = notification.similar_articles

        // Count successful transfers
        let blobCount = [
            titleBlob, bodyBlob, summaryBlob, criticalAnalysisBlob,
            logicalFallaciesBlob, sourceAnalysisBlob, relationToTopicBlob,
            additionalInsightsBlob,
        ].compactMap { $0 }.count

        AppLogger.database.debug("✅ Blob update complete: transferred \(blobCount) valid blobs")
    }

    /// Regenerates missing or invalid blobs by using markdown content
    @MainActor
    func regenerateMissingBlobs() -> Int {
        var regeneratedCount = 0

        // Helper to regenerate a specific blob
        func regenerateBlob(text: String?, existingBlob: Data?, field: RichTextField, setBlob: (Data?) -> Void) {
            // Skip if text is empty or blob already exists
            guard let text = text, !text.isEmpty else { return }

            // If blob exists, check if it's valid
            if let blob = existingBlob, !blob.isEmpty {
                do {
                    if let _ = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: blob) {
                        // Blob is valid, skip regeneration
                        return
                    }
                } catch {
                    // Invalid blob, continue to regenerate
                    AppLogger.database.debug("🔄 Replacing invalid blob for \(String(describing: field))")
                }
            }

            // Generate new attributed string
            if let attributedString = markdownToAttributedString(text, textStyle: field.textStyle) {
                do {
                    // Archive to data
                    let blobData = try NSKeyedArchiver.archivedData(
                        withRootObject: attributedString,
                        requiringSecureCoding: false
                    )

                    // Update blob
                    setBlob(blobData)
                    regeneratedCount += 1
                    AppLogger.database.debug("✅ Regenerated blob for \(String(describing: field)): \(blobData.count) bytes")
                } catch {
                    AppLogger.database.error("❌ Failed to archive blob for \(String(describing: field)): \(error)")
                }
            }
        }

        // Regenerate blobs for each field
        regenerateBlob(text: title, existingBlob: titleBlob, field: .title) { self.titleBlob = $0 }
        regenerateBlob(text: body, existingBlob: bodyBlob, field: .body) { self.bodyBlob = $0 }
        regenerateBlob(text: summary, existingBlob: summaryBlob, field: .summary) { self.summaryBlob = $0 }
        regenerateBlob(text: criticalAnalysis, existingBlob: criticalAnalysisBlob, field: .criticalAnalysis) { self.criticalAnalysisBlob = $0 }
        regenerateBlob(text: logicalFallacies, existingBlob: logicalFallaciesBlob, field: .logicalFallacies) { self.logicalFallaciesBlob = $0 }
        regenerateBlob(text: sourceAnalysis, existingBlob: sourceAnalysisBlob, field: .sourceAnalysis) { self.sourceAnalysisBlob = $0 }
        regenerateBlob(text: relationToTopic, existingBlob: relationToTopicBlob, field: .relationToTopic) { self.relationToTopicBlob = $0 }
        regenerateBlob(text: additionalInsights, existingBlob: additionalInsightsBlob, field: .additionalInsights) { self.additionalInsightsBlob = $0 }

        if regeneratedCount > 0 {
            AppLogger.database.debug("✅ Regenerated \(regeneratedCount) blobs for ArticleModel \(id)")
        }

        return regeneratedCount
    }
}

/// Provides conversion methods between SeenArticleModel and SeenArticle
extension SeenArticle {
    /// Creates a SeenArticle from a SeenArticleModel
    static func from(seenArticleModel: SeenArticleModel) -> SeenArticle {
        return SeenArticle(
            id: seenArticleModel.id,
            json_url: seenArticleModel.jsonURL,
            date: seenArticleModel.date
        )
    }
}
