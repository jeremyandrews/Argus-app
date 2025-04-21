# R2 URL JSON New Fields

## Overview

Two new fields have been added to the JSON payload sent to the R2 URL for the iOS application that transform passive news consumption into active engagement:

1. `action_recommendations`: Concrete, actionable steps users can take based on article content
2. `talking_points`: Thought-provoking discussion points to facilitate sharing and conversation

These fields provide users with practical ways to engage with content beyond simply reading it.

## Field Specifications

### action_recommendations

**Description**:
Contains 3-5 concrete, actionable recommendations based on the article content. These are practical steps a user could take in response to the information in the article.

**Format**:
- **Type**: String
- **Structure**: Markdown-formatted text with bullet points
- **Length**: Typically 3-5 bullet points, each 25-40 words
- **Style**: Each point starts with a strong action verb highlighted in bold

**Example**:
```markdown
- **Download the security patch** released by Microsoft immediately, as it addresses the critical Windows vulnerability that has already compromised over 100,000 systems worldwide.
- **Enable two-factor authentication** on all cloud services mentioned in the article, particularly those handling sensitive data like financial or healthcare information.
- **Review your organization's response plan** for ransomware attacks, ensuring it addresses the specific threats detailed by the security researchers at Black Hat 2024.
```

**Implementation Notes**:
- Action recommendations are tied directly to article content, not generic advice
- Each recommendation begins with a bold action verb
- Recommendations vary based on article type (news events, technology, policy changes, etc.)
- iOS app preserves formatting, particularly the bold highlighting of initial verbs

### talking_points

**Description**:
Contains 3-5 thought-provoking discussion points that facilitate sharing and conversation about the article's content. These help users engage others in meaningful dialogue about the topic.

**Format**:
- **Type**: String
- **Structure**: Markdown-formatted text with bullet points
- **Length**: Typically 3-5 bullet points, each 30-50 words
- **Style**: Each point is either a discussion-starter question OR a bold statement + follow-up question

**Example**:
```markdown
- **How might the facial recognition limitations** described in the article affect different demographic groups unequally, given the researchers found a 35% higher error rate for certain populations?
- **The article suggests that companies are rushing AI deployment before adequate testing.** How should we balance innovation speed with safety in emerging technologies?
- **Is the 5-year timeline for quantum computing breakthroughs** realistic given the technical challenges outlined by the MIT researchers, or are the commercial predictions overly optimistic?
```

**Implementation Notes**:
- Talking points often highlight implications, controversies, or nuances in the article
- Points contain specific references to article content
- Format varies between discussion questions and statement/question combinations
- iOS app preserves formatting, particularly the bold highlighting of key phrases

## JSON Structure Example

```json
{
  "topic": "Technology",
  "title": "New Security Vulnerability Found in Windows",
  "url": "https://example.com/article-url",
  "article_body": "Full article text...",
  "pub_date": "2025-04-15",
  "summary": "...",
  "critical_analysis": "...",
  "logical_fallacies": "...",
  
  "action_recommendations": "- **Download the security patch** released by Microsoft immediately, as it addresses the critical Windows vulnerability that has already compromised over 100,000 systems worldwide.\n- **Enable two-factor authentication** on all cloud services mentioned in the article, particularly those handling sensitive data.\n- **Review your organization's response plan** for ransomware attacks, ensuring it addresses the specific threats detailed.",
  
  "talking_points": "- **How might the exploitation methods** described in the article affect different types of organizations, given that healthcare institutions were shown to be particularly vulnerable?\n- **The security researchers waited 90 days before disclosure.** Is this standard timeline appropriate for critical vulnerabilities like this one?\n- **What responsibility do software vendors have** to ensure security in legacy systems that are still widely used but officially unsupported?",
  
  "additional_insights": "...",
  "sources_quality": 3,
  "argument_quality": 3,
  "quality": 4,
  "source_type": "press",
  "elapsed_time": 4.52,
  "model": "llama3"
}
```

## Technical Implementation

1. **Data Models**:
   - Added fields to `ArticleJSON` and `PreparedArticle` structs
   - Added properties and blob storage fields to `ArticleModel`
   - Created API compatibility extensions

2. **Data Processing**:
   - Modified `DatabaseCoordinator.syncProcessArticleJSON()` to extract fields
   - Updated the `ArticleModel` constructor
   - Updated `updateFields()` to properly handle the new fields

3. **Rich Text Handling**:
   - Added cases to `RichTextField` enum in MarkdownUtilities.swift
   - Implemented section naming and mapping
   - Updated all affected methods to handle the new fields
   - Included in verification and regeneration functions

4. **UI Integration**:
   - Added sections to NewsDetailView
   - Updated default expanded sections list
   - Modified getTextContentForField to extract values
   - Updated needsConversion for Markdown formatting

These new fields provide actionable value to users, helping them move from passive consumption to active engagement with article content.
