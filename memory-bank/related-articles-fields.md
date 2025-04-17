# Related Articles Fields

## Overview

This document details the new fields added to the similar articles section of the JSON payload. These fields provide deeper insights into the similarity calculation between articles, enhancing transparency and user understanding of why articles are considered related.

## API Response Structure

Each article in the `similar_articles` array now includes the following additional fields:

```json
{
  "similar_articles": [
    {
      // Existing fields
      "id": 123,
      "json_url": "https://r2.example.com/abc123.json",
      "title": "Article Title",
      "tiny_summary": "Brief summary...",
      "category": "Technology",
      "published_date": "2025-04-15",
      "quality_score": 3,
      "similarity_score": 0.87,
      
      // New vector quality fields
      "vector_score": 0.85,
      "vector_active_dimensions": 768,
      "vector_magnitude": 1.23,
      
      // New entity similarity fields
      "entity_overlap_count": 7,
      "primary_overlap_count": 3,
      "person_overlap": 0.75,
      "org_overlap": 0.60,
      "location_overlap": 0.40,
      "event_overlap": 0.80,
      "temporal_proximity": 0.95,
      
      // Formula explanation
      "similarity_formula": "60% vector similarity (0.85) + 40% entity similarity (0.70), where entity similarity combines person (30%), organization (20%), location (15%), event (15%), and temporal (20%) factors"
    }
  ]
}
```

## Field Descriptions

### Vector Quality Fields

| Field | Type | Description |
|-------|------|-------------|
| `vector_score` | FloatNullable | The raw vector similarity score (cosine similarity) between this article and the query article, before any weighting is applied. Range: 0-1, where 1 indicates identical vectors. May be null if only entity matching was performed. |
| `vector_active_dimensions` | IntegerNullable | The number of dimensions in the embedding vector that are actively contributing to the similarity calculation. Higher numbers can indicate more nuanced embedding. May be null if this data isn't available. |
| `vector_magnitude` | FloatNullable | The L2 norm (magnitude) of the article's embedding vector. Indicates the "strength" of the vector representation. May be null if this data isn't available. |

### Entity Similarity Fields

| Field | Type | Description |
|-------|------|-------------|
| `entity_overlap_count` | IntegerNullable | The total number of entities (people, organizations, locations, events) that appear in both the query article and this article, regardless of importance level. May be null if no entity matching was performed. |
| `primary_overlap_count` | IntegerNullable | The number of PRIMARY importance entities that appear in both articles. PRIMARY entities are the main subjects of the article and have greater weight in similarity calculations. May be null if no entity matching was performed. |
| `person_overlap` | FloatNullable | Similarity score (0-1) based specifically on people/persons mentioned in both articles. Higher values indicate more shared key people. May be null if no entity matching was performed or no person entities were found. |
| `org_overlap` | FloatNullable | Similarity score (0-1) based on organizations mentioned in both articles. Higher values indicate more shared key organizations. May be null if no entity matching was performed or no organization entities were found. |
| `location_overlap` | FloatNullable | Similarity score (0-1) based on locations mentioned in both articles. Higher values indicate more shared key locations. May be null if no entity matching was performed or no location entities were found. |
| `event_overlap` | FloatNullable | Similarity score (0-1) based on events mentioned in both articles. Higher values indicate more shared key events. May be null if no entity matching was performed or no event entities were found. |
| `temporal_proximity` | FloatNullable | Similarity score (0-1) based on how close the articles' event dates are to each other. 1.0 means same date, with decreasing values for more temporally distant events. May be null if no event dates were available or extracted. |

### Formula Explanation

| Field | Type | Description |
|-------|------|-------------|
| `similarity_formula` | StringNullable | A human-readable explanation of how the final similarity score was calculated, including the weights and component scores used. Format is consistent but the actual values will vary per article match. May be null if similarity calculation details aren't available. |

## Formula Calculation Details

The final `similarity_score` is calculated using this formula:

```
similarity_score = (0.6 * vector_score) + (0.4 * entity_similarity)
```

Where `entity_similarity` is calculated as:

```
entity_similarity = (0.3 * person_overlap) + 
                   (0.2 * org_overlap) + 
                   (0.15 * location_overlap) + 
                   (0.15 * event_overlap) + 
                   (0.2 * temporal_proximity)
```

## Field Availability Notes

- All new fields are optional and may be null in certain scenarios
- Pure vector matches will have vector fields but may lack entity fields
- Entity-only matches may have limited vector fields
- The similarity_formula provides context about which components contributed to the final score
- Always check for null values before using these fields in calculations or displays

## Implementation Strategy

### Data Model Updates

1. Update `APIRelatedArticle` struct:
   - Add all new fields with appropriate Swift types
   - Update CodingKeys enum to map snake_case API names to camelCase Swift properties

2. Update `RelatedArticle` struct:
   - Add the same new fields
   - Update the initializer to accept and store the new fields from APIRelatedArticle
   - Add computed properties for formatting values for display

### UI Display Recommendations

1. **Progressive Disclosure**:
   - Show basic similarity score by default
   - Use expandable sections for detailed vector and entity metrics
   - Keep the formula explanation in a dedicated expandable section

2. **Visual Indicators**:
   - Use color-coded bars for similarity percentages
   - Consider small icons for entity types (person, organization, location)
   - Use mini-charts for comparing the different overlap types

3. **Explanatory Text**:
   - Add brief tooltips explaining what each metric means
   - Make the similarity formula human-readable with proper formatting
