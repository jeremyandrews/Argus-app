import Foundation
import SwiftData
import SQLite3

// MARK: - Lightweight Models for List Views

/// Lightweight article model for list display - no SwiftData overhead
struct ArticleListItem: Identifiable, Sendable {
    let id: UUID
    let title: String
    let body: String  // Using body instead of summary for list display
    let topic: String
    let publishDate: Date
    var isViewed: Bool  // Made mutable for state updates
    var isBookmarked: Bool  // Made mutable for state updates
    let quality: String
    let qualityScore: Int
    let affected: String
    let domain: String?
    let sourceType: String?
    let sourcesQuality: String?
    let argumentQuality: String?
    
    /// Quick quality check for filtering
    func meetsQualityFilter(_ filter: String) -> Bool {
        switch filter {
        case "All": return true
        case "Fair+": return qualityScore >= 3
        case "Good+": return qualityScore >= 7
        default: return true
        }
    }
}

// MARK: - Fast Query Service

/// Service for fast article list queries using raw SQLite
@MainActor
final class ArticleListService {
    
    /// Shared instance
    static let shared = ArticleListService()
    
    /// SQLite database handle
    private var db: OpaquePointer?
    
    /// Cache for compiled statements
    private var statements: [String: OpaquePointer] = [:]
    
    init() {
        openDatabase()
        prepareStatements()
    }
    
    deinit {
        statements.forEach { _, stmt in
            sqlite3_finalize(stmt)
        }
        sqlite3_close(db)
    }
    
    // MARK: - Database Setup
    
    private func openDatabase() {
        // Get the SwiftData store URL - it's stored in Documents/ArgusTestDB.store
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let storeURL = documentsDirectory.appendingPathComponent("ArgusTestDB.store")
        
        AppLogger.database.debug("Opening database at: \(storeURL.path)")
        
        if sqlite3_open_v2(storeURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            AppLogger.database.debug("Successfully opened database for fast queries")
            
            // Check what tables exist
            checkDatabaseTables()
        } else {
            if let errorMessage = sqlite3_errmsg(db) {
                let error = String(cString: errorMessage)
                AppLogger.database.error("Failed to open database: \(error)")
            } else {
                AppLogger.database.error("Failed to open database for reading")
            }
        }
    }
    
    private func checkDatabaseTables() {
        let sql = "SELECT name FROM sqlite_master WHERE type='table'"
        var stmt: OpaquePointer?
        
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            var tables: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let tableName = sqlite3_column_text(stmt, 0) {
                    tables.append(String(cString: tableName))
                }
            }
            AppLogger.database.debug("Database tables found: \(tables.joined(separator: ", "))")
        } else {
            AppLogger.database.error("Failed to query database tables")
        }
        sqlite3_finalize(stmt)
    }
    
    private func prepareStatements() {
        // Prepare commonly used statements
        let topicQuery = """
            SELECT Z_PK, ZAFFECTED, ZARGUMENTQUALITY, ZBODY, ZDOMAIN, 
                   ZISBOOKMARKED, ZISVIEWED, ZPUBLISHDATE, ZQUALITY, 
                   ZQUALITYSCORE, ZSOURCEANALYSIS, ZSOURCESQUALITY, 
                   ZSOURCETYPE, ZSUMMARY, ZTITLE, ZTOPIC, ZUUID
            FROM ZARTICLEMODEL
            WHERE ZTOPIC = ?
            ORDER BY ZPUBLISHDATE DESC
            LIMIT 500
        """
        
        let allQuery = """
            SELECT Z_PK, ZAFFECTED, ZARGUMENTQUALITY, ZBODY, ZDOMAIN, 
                   ZISBOOKMARKED, ZISVIEWED, ZPUBLISHDATE, ZQUALITY, 
                   ZQUALITYSCORE, ZSOURCEANALYSIS, ZSOURCESQUALITY, 
                   ZSOURCETYPE, ZSUMMARY, ZTITLE, ZTOPIC, ZUUID
            FROM ZARTICLEMODEL
            ORDER BY ZPUBLISHDATE DESC
            LIMIT 500
        """
        
        prepareStatement(topicQuery, key: "topic")
        prepareStatement(allQuery, key: "all")
    }
    
    private func prepareStatement(_ sql: String, key: String) {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            statements[key] = stmt
        } else {
            AppLogger.database.error("Failed to prepare statement: \(key)")
        }
    }
    
    // MARK: - Public Query Methods
    
    /// Fetch articles for list display with ultra-fast raw queries
    func fetchArticlesForList(
        topic: String? = nil,
        showUnreadOnly: Bool = false,
        showBookmarkedOnly: Bool = false,
        qualityFilter: String = "All"
    ) async -> [ArticleListItem] {
        
        var articles: [ArticleListItem] = []
        
        // Build and execute query
        let sql: String
        if let topic = topic, topic != "All" {
            sql = """
                SELECT ZUUID, ZTITLE, ZBODY, ZTOPIC, ZPUBLISHDATE,
                       ZISVIEWED, ZISBOOKMARKED, ZQUALITY, ZQUALITYSCORE,
                       ZAFFECTED, ZDOMAIN, ZSOURCETYPE, ZSOURCESQUALITY, ZARGUMENTQUALITY
                FROM ZARTICLEMODEL
                WHERE ZTOPIC = '\(topic)'
                \(showUnreadOnly ? "AND ZISVIEWED = 0" : "")
                \(showBookmarkedOnly ? "AND ZISBOOKMARKED = 1" : "")
                \(qualityFilter == "Fair+" ? "AND ZQUALITYSCORE >= 3" : "")
                \(qualityFilter == "Good+" ? "AND ZQUALITYSCORE >= 7" : "")
                ORDER BY ZPUBLISHDATE DESC
                LIMIT 500
            """
        } else {
            sql = """
                SELECT ZUUID, ZTITLE, ZBODY, ZTOPIC, ZPUBLISHDATE,
                       ZISVIEWED, ZISBOOKMARKED, ZQUALITY, ZQUALITYSCORE,
                       ZAFFECTED, ZDOMAIN, ZSOURCETYPE, ZSOURCESQUALITY, ZARGUMENTQUALITY
                FROM ZARTICLEMODEL
                WHERE 1=1
                \(showUnreadOnly ? "AND ZISVIEWED = 0" : "")
                \(showBookmarkedOnly ? "AND ZISBOOKMARKED = 1" : "")
                \(qualityFilter == "Fair+" ? "AND ZQUALITYSCORE >= 3" : "")
                \(qualityFilter == "Good+" ? "AND ZQUALITYSCORE >= 7" : "")
                ORDER BY ZPUBLISHDATE DESC
                LIMIT 500
            """
        }
        
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let article = parseArticleFromRow(stmt!)
                articles.append(article)
            }
        }
        sqlite3_finalize(stmt)
        
        AppLogger.database.debug("Fast query returned \(articles.count) articles")
        return articles
    }
    
    /// Get distinct topics for topic bar
    func getDistinctTopics() async -> [String] {
        var topics: Set<String> = []
        
        let sql = "SELECT DISTINCT ZTOPIC FROM ZARTICLEMODEL WHERE ZTOPIC IS NOT NULL"
        
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let topicCStr = sqlite3_column_text(stmt, 0) {
                    let topic = String(cString: topicCStr)
                    topics.insert(topic)
                }
            }
        }
        sqlite3_finalize(stmt)
        
        return Array(topics).sorted()
    }
    
    /// Get article count for a topic
    func getArticleCount(for topic: String?, filters: (Bool, Bool, String)) async -> Int {
        let (showUnreadOnly, showBookmarkedOnly, qualityFilter) = filters
        
        let sql: String
        if let topic = topic, topic != "All" {
            sql = """
                SELECT COUNT(*) FROM ZARTICLEMODEL
                WHERE ZTOPIC = '\(topic)'
                \(showUnreadOnly ? "AND ZISVIEWED = 0" : "")
                \(showBookmarkedOnly ? "AND ZISBOOKMARKED = 1" : "")
                \(qualityFilter == "Fair+" ? "AND ZQUALITYSCORE >= 3" : "")
                \(qualityFilter == "Good+" ? "AND ZQUALITYSCORE >= 7" : "")
            """
        } else {
            sql = """
                SELECT COUNT(*) FROM ZARTICLEMODEL
                WHERE 1=1
                \(showUnreadOnly ? "AND ZISVIEWED = 0" : "")
                \(showBookmarkedOnly ? "AND ZISBOOKMARKED = 1" : "")
                \(qualityFilter == "Fair+" ? "AND ZQUALITYSCORE >= 3" : "")
                \(qualityFilter == "Good+" ? "AND ZQUALITYSCORE >= 7" : "")
            """
        }
        
        var stmt: OpaquePointer?
        var count = 0
        
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                count = Int(sqlite3_column_int(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)
        
        return count
    }
    
    // MARK: - Helper Methods
    
    private func parseArticleFromRow(_ stmt: OpaquePointer) -> ArticleListItem {
        // Parse UUID (stored as blob in SwiftData)
        let uuidBytes = sqlite3_column_blob(stmt, 0)
        let uuidLength = sqlite3_column_bytes(stmt, 0)
        let uuidData = Data(bytes: uuidBytes!, count: Int(uuidLength))
        let uuid = UUID(uuid: uuid_t(
            uuidData[0], uuidData[1], uuidData[2], uuidData[3],
            uuidData[4], uuidData[5], uuidData[6], uuidData[7],
            uuidData[8], uuidData[9], uuidData[10], uuidData[11],
            uuidData[12], uuidData[13], uuidData[14], uuidData[15]
        ))
        
        // Parse strings
        let title: String
        if let titlePtr = sqlite3_column_text(stmt, 1) {
            title = String(cString: titlePtr)
        } else {
            title = ""
        }
        
        let body: String
        if let bodyPtr = sqlite3_column_text(stmt, 2) {
            body = String(cString: bodyPtr)
        } else {
            body = ""
        }
        
        let topic: String
        if let topicPtr = sqlite3_column_text(stmt, 3) {
            topic = String(cString: topicPtr)
        } else {
            topic = ""
        }
        
        // Parse date (stored as NSTimeInterval since 2001)
        let dateInterval = sqlite3_column_double(stmt, 4)
        let publishDate = Date(timeIntervalSinceReferenceDate: dateInterval)
        
        // Parse booleans
        let isViewed = sqlite3_column_int(stmt, 5) != 0
        let isBookmarked = sqlite3_column_int(stmt, 6) != 0
        
        // Parse quality
        let quality: String
        if let qualityPtr = sqlite3_column_text(stmt, 7) {
            quality = String(cString: qualityPtr)
        } else {
            quality = ""
        }
        let qualityScore = Int(sqlite3_column_int(stmt, 8))
        
        // Parse optional fields
        let affected: String
        if let affectedPtr = sqlite3_column_text(stmt, 9) {
            affected = String(cString: affectedPtr)
        } else {
            affected = ""
        }
        
        let domain: String? = sqlite3_column_type(stmt, 10) != SQLITE_NULL ? 
            String(cString: sqlite3_column_text(stmt, 10)!) : nil
            
        let sourceType: String? = sqlite3_column_type(stmt, 11) != SQLITE_NULL ?
            String(cString: sqlite3_column_text(stmt, 11)!) : nil
            
        let sourcesQuality: String? = sqlite3_column_type(stmt, 12) != SQLITE_NULL ?
            String(cString: sqlite3_column_text(stmt, 12)!) : nil
            
        let argumentQuality: String? = sqlite3_column_type(stmt, 13) != SQLITE_NULL ?
            String(cString: sqlite3_column_text(stmt, 13)!) : nil
        
        return ArticleListItem(
            id: uuid,
            title: title,
            body: body,
            topic: topic,
            publishDate: publishDate,
            isViewed: isViewed,
            isBookmarked: isBookmarked,
            quality: quality,
            qualityScore: qualityScore,
            affected: affected,
            domain: domain,
            sourceType: sourceType,
            sourcesQuality: sourcesQuality,
            argumentQuality: argumentQuality
        )
    }
}
