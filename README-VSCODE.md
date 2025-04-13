# VSCode Configuration for Swift Development

This project contains configuration files that help VSCode better understand Swift code in the Argus iOS app. These configs allow VSCode to show useful errors while suppressing false positives.

## Files Created

1. **`.sourcekit-lsp`** (Project Root)
   - Configures Apple's SourceKit-LSP language server
   - Selectively disables specific types of diagnostics that cause false errors
   - Enables code completion and intelligent indexing
   - Maintains useful error reporting while suppressing known false positives

2. **`.vscode/settings.json`**
   - Sets VSCode environment for Swift development
   - Points to Xcode project for proper code context
   - Configures editor behavior for Swift files
   - Excludes non-Swift files (documentation, Package.swift) from Swift analysis
   - Treats problematic files as plaintext to avoid invalid Swift errors

3. **`.vscode/swift.exclude`**
   - Tells the Swift language server which paths to completely ignore
   - Prevents analysis of non-Swift files like markdown documentation

4. **`.vscode/swift-snippets.json`**
   - Provides useful code snippets for Swift development
   - Includes common import patterns for the Argus project

5. **`.vscode/extensions.json`**
   - Recommends essential Swift extensions for VSCode:
     - `swiftlang.swift-vscode`: Official Swift extension (latest version)
     - `vadimcn.vscode-lldb`: Debugging support

6. **`.vscode/tasks.json`**
   - Provides helpful commands for Swift development:
     - "Open Xcode Project": Opens the project in Xcode
     - "Clean VSCode Swift Cache": Clears language server cache
     - "Restart SourceKit-LSP": Instructions to restart the language server

7. **`Package.swift`** (Project Root)
   - Helps SourceKit-LSP understand the project structure
   - Not used for actual building (which happens in Xcode)

## Usage

### After Initial Setup:

The configuration changes will only take full effect after restarting the SourceKit-LSP service:

1. Run the "Clean VSCode Swift Cache" task from the Command Palette (Cmd+Shift+P)
2. Reload the VSCode window using Command Palette → "Developer: Reload Window"
3. Open your Swift files again

### What to Expect:

- Legitimate Swift errors will still appear
- False positives in files like MigrationService.swift should be eliminated
- Documentation files and Package.swift won't trigger Swift errors
- Code navigation and completion should work as expected

## Known Limitations

- VSCode's Swift support is still not as complete as Xcode
- Some complex Swift features may not be fully understood by VSCode
- Swift Package Manager support in VSCode is limited
- Auto-completion might occasionally be less accurate than in Xcode

## Troubleshooting

If you still see false errors after installation:

1. Ensure all the recommended extensions are installed
2. Run the "Clean VSCode Swift Cache" task
3. Completely close and reopen VSCode
4. Verify the files showing errors are not in .vscode/swift.exclude or settings.json exclude patterns
5. Check if they are Swift files that might need additional imports
