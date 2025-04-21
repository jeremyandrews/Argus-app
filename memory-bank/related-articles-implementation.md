# Related Articles Implementation

## Overview

The related articles feature displays content similar to the current article, with detailed similarity metrics explaining *why* articles are considered related. This document captures the actual implementation details after bug fixes and enhancements.

## Implementation Structure

### Data Model Architecture

The implementation uses a two-model approach to solve date parsing issues:

1. **API Model** (`APIRelatedArticle`):
   - Dedicated for decoding JSON responses from the API
   - Handles ISO8601 date strings from the server (`published_date` as string)
   - Maps snake_case field names from API to camelCase
   - Includes all similarity metric fields
   - Provides conversion to database model via `toRelatedArticle()`

2. **Database Model** (`RelatedArticle`):
   - Used for storage and UI display
   - Stores dates as Date objects (not strings)
   - Includes computed properties for formatting display values
   - Explicit Codable implementation with `secondsSince1970` date strategy
   - Used for both storage and retrieval

### Processing Flow

1. **API Response Parsing**:
   ```swift
   // First decode using the API model that handles ISO8601 string dates from the API
   let decoder = JSONDecoder()
   let apiRelatedArticles = try decoder.decode([APIRelatedArticle].self, from: data)
   
   // Convert API models to database models with proper date conversion
   parsedRelatedArticles = apiRelatedArticles.map { $0.toRelatedArticle() }
   ```

2. **Database Storage**:
   ```swift
   // Create encoder with explicit date strategy
   let encoder = JSONEncoder()
   // Use seconds since 1970 format (default, but being explicit)
   encoder.dateEncodingStrategy = .secondsSince1970
   
   relatedArticlesData = try encoder.encode(newValue)
   ```

3. **Database Retrieval**:
   ```swift
   // Create decoder with explicit date strategy
   let decoder = JSONDecoder()
   // Use seconds since 1970 format (default for JSONEncoder)
   decoder.dateDecodingStrategy = .secondsSince1970
   
   let decodedArticles = try decoder.decode([RelatedArticle].self, from: data)
   ```

## Key Bug Fixes

We fixed several assumptions that were causing issues:

1. **Incorrect Date Format Assumption** ✓ FIXED
   - **Problem**: The system assumed the same date format in both API responses and database storage
   - **Reality**: API uses ISO8601 strings while database uses numeric timestamps
   - **Solution**: Created separate models with appropriate date handling for each context

2. **Single Decoder Assumption** ✓ FIXED
   - **Problem**: Using a single decoder for both contexts led to type mismatches
   - **Reality**: Different contexts need different decoding strategies
   - **Solution**: Implemented a two-step decode process with conversion between models

3. **Missing Type Safety** ✓ FIXED
   - **Problem**: Direct JSON parsing was prone to errors
   - **Reality**: Strongly typed models ensure consistency
   - **Solution**: Implemented proper Codable conformance with explicit CodingKeys

4. **Inconsistent Error Handling** ✓ FIXED
   - **Problem**: Some parsing errors weren't properly caught or logged
   - **Reality**: Parsing can fail in multiple ways
   - **Solution**: Added comprehensive error handling with detailed logging

## UI Implementation

The UI follows a progressive disclosure pattern with three key components:

1. **`EnhancedRelatedArticlesView`**: Main container that displays a list of related articles
2. **`EnhancedRelatedArticleRow`**: Individual article row with expandable details
3. **Detail Components**:
   - `VectorDetailsView`: Shows vector similarity metrics
   - `EntityDetailsView`: Shows entity overlap metrics
   - `FormulaExplanationView`: Explains similarity calculation

UI features include:
- Expandable sections to prevent information overload
- Color-coded similarity badges
- Visual metric bars for easy comparison
- Tooltips for technical explanations
- Comprehensive error handling

## Similarity Metrics

The implementation includes several metrics to explain article similarity:

1. **Vector Similarity**:
   - `vectorScore`: Raw vector similarity (cosine similarity)
   - `vectorActiveDimensions`: Number of embedding dimensions
   - `vectorMagnitude`: Vector strength indicator

2. **Entity Similarity**:
   - `entityOverlapCount`: Total shared entities
   - `primaryOverlapCount`: Primary shared entities
   - `personOverlap`: People/persons similarity score
   - `orgOverlap`: Organizations similarity score
   - `locationOverlap`: Locations similarity score
   - `eventOverlap`: Events similarity score
   - `temporalProximity`: Time closeness score

3. **Overall Formula**:
   - Human-readable explanation of how similarity was calculated
   - Includes component weights and individual scores

## Lessons Learned

1. **Context-Specific Models**: Different data contexts (API, database, UI) benefit from dedicated models
2. **Explicit Date Handling**: Always specify encoding/decoding strategies for dates
3. **Two-Step Parsing**: Convert between models with explicit transformations
4. **Progressive Disclosure**: Complex data is best presented in layers
5. **Comprehensive Logging**: Log both successes and failures for easier debugging
