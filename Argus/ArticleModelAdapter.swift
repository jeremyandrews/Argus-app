import Foundation
import SwiftData
import SwiftUI

/// Provides conversion methods between ArticleModel and NotificationData
extension NotificationData {
    /// Creates a NotificationData object from an ArticleModel
    /// This allows the UI layer to continue working with NotificationData while
    /// the data layer works with the new ArticleModel
    static func from(articleModel: ArticleModel) -> NotificationData {
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
            isArchived: articleModel.isArchived,
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
            title_blob: articleModel.titleBlob,
            body_blob: articleModel.bodyBlob,
            summary_blob: articleModel.summaryBlob,
            critical_analysis_blob: articleModel.criticalAnalysisBlob,
            logical_fallacies_blob: articleModel.logicalFallaciesBlob,
            source_analysis_blob: articleModel.sourceAnalysisBlob,
            relation_to_topic_blob: articleModel.relationToTopicBlob,
            additional_insights_blob: articleModel.additionalInsightsBlob,
            engine_stats: articleModel.engineStats,
            similar_articles: articleModel.similarArticles
        )
        return notification
    }
}

/// Extension to update ArticleModel blobs from NotificationData
extension ArticleModel {
    /// Updates blob data from a NotificationData object
    func updateBlobs(from notification: NotificationData) {
        titleBlob = notification.title_blob
        bodyBlob = notification.body_blob
        summaryBlob = notification.summary_blob
        criticalAnalysisBlob = notification.critical_analysis_blob
        logicalFallaciesBlob = notification.logical_fallacies_blob
        sourceAnalysisBlob = notification.source_analysis_blob
        relationToTopicBlob = notification.relation_to_topic_blob
        additionalInsightsBlob = notification.additional_insights_blob

        // Update the engine stats and similar articles fields too
        engineStats = notification.engine_stats
        similarArticles = notification.similar_articles
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
