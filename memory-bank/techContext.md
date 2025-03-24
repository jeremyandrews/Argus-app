# Technical Context: Argus iOS App

## Development Environment
- **Platform**: iOS
- **Minimum iOS Version**: iOS 18
- **Development Tools**: Xcode
- **Version Control**: Git

## Core Technologies

### Frontend
- **Language**: Swift
- **UI Framework**: SwiftUI
- **State Management**: Combine framework, @Published properties, ObservableObject

### Networking
- **Protocol**: HTTPS
- **API Style**: RESTful
- **Authentication**: JWT
- **Data Format**: JSON for API communication, Markdown for article content

### Persistence
- **Local Storage**: Likely CoreData or SQLite
- **Caching**: In-memory and disk caching for articles and images
- **User Preferences**: UserDefaults for app settings

### Background Processing
- **Push Notifications**: Apple Push Notification Service (APNS)
- **Background Fetch**: iOS Background Tasks framework
- **Background Modes**: Background fetch, remote notifications

## Key Dependencies
(Note: Based on project structure, specific third-party libraries would be listed here)

## Infrastructure
- **Backend**: Custom backend service providing AI-enhanced news content
- **Push Notification Service**: APNS with authentication key
- **Content Delivery**: Backend API

## Testing Infrastructure
- **Unit Testing**: XCTest framework
- **UI Testing**: XCUITest
- **Test Data**: Mock data for offline testing

## Security Considerations
- **Data Privacy**: Local storage of user preferences and articles
- **Network Security**: HTTPS for all API communications
- **Authentication**: Secure handling of API credentials
- **User Data**: Minimizing collection of personal information

## Performance Constraints
- **Offline Capability**: App must function without internet connection
- **Memory Management**: Efficient handling of potentially large article collections
- **Battery Usage**: Minimizing background processing impact
- **Network Efficiency**: Smart sync to reduce data usage

## Technical Debt and Limitations
- It's difficult to make large changes to the database layer
- The UI is jittery during the sync process: needs to be fixed
- Sometimes duplicate content is displayed: needs to be fixed

## Development Workflow
- **Feature Branches**: Development of new features in isolated branches
- **Code Review**: Pull request review process
- **CI/CD**: Automated testing before merging to main branch
- **Release Process**: TestFlight distribution before App Store submission

## Technical Documentation
- Swift documentation comments
- Architecture diagrams
- API specifications
