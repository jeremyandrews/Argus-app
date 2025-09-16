#!/bin/bash

# Performance Test Runner for Argus App
# This script runs the performance tests and provides guidance on reading results

echo "========================================"
echo "Argus Performance Test Runner"
echo "========================================"
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo "🚀 Starting performance tests..."
echo ""
echo "NOTE: The tests will measure the following operations:"
echo ""
echo -e "${BLUE}1. Topic Switching Performance${NC}"
echo "   - Switching between 7 different topics"
echo "   - Target: < 500ms per switch"
echo ""
echo -e "${BLUE}2. Article Detail View Performance${NC}"
echo "   - Opening article detail view"
echo "   - Loading tiny title and summary"
echo "   - Loading full content"
echo "   - Target: < 300ms to open, < 1s for full content"
echo ""
echo -e "${BLUE}3. Section Expansion Performance${NC}"
echo "   - Expanding Simple Breakdown"
echo "   - Expanding Context & Perspective"
echo "   - Expanding Critical Analysis"
echo "   - Target: < 200ms per expansion"
echo ""
echo -e "${BLUE}4. Article Navigation${NC}"
echo "   - Moving to next/previous article"
echo "   - Target: < 300ms"
echo ""

echo "========================================"
echo "Running Tests..."
echo "========================================"
echo ""

# Run the tests
xcodebuild test \
    -scheme Argus \
    -destination 'platform=iOS Simulator,name=iPhone 16' \
    -only-testing:ArgusUITests/PerformanceTestSuite \
    2>&1 | tee test_output.log | grep -E "(Test Case|passed|failed|measured)"

echo ""
echo "========================================"
echo "How to Read the Results"
echo "========================================"
echo ""
echo -e "${GREEN}✅ In Xcode (Most Detailed):${NC}"
echo "1. Open Xcode"
echo "2. Press ⌘+9 to open Report Navigator"
echo "3. Find the test run (latest at top)"
echo "4. Click on 'PerformanceTestSuite'"
echo "5. For each test, you'll see:"
echo "   • Average time (main metric)"
echo "   • Standard deviation"
echo "   • Min/Max values"
echo "   • All 5 iteration times"
echo ""

echo -e "${GREEN}✅ Performance Metrics Interpretation:${NC}"
echo ""
echo "When you see: 'measured [Time, seconds] average: 0.245'"
echo "This means: The operation took 245 milliseconds on average"
echo ""
echo "Standard deviation shows consistency:"
echo "• < 10% = Very consistent"
echo "• 10-20% = Acceptable variance"
echo "• > 20% = High variance (investigate)"
echo ""

echo -e "${GREEN}✅ Performance Ratings:${NC}"
echo ""
echo "Based on our thresholds:"
echo -e "${GREEN}Excellent:${NC} < 50% of target"
echo -e "${GREEN}Good:${NC} 50-75% of target"
echo -e "${YELLOW}Warning:${NC} 75-100% of target"
echo -e "${RED}Critical:${NC} > target"
echo ""

echo "========================================"
echo "Expected Performance Targets"
echo "========================================"
echo ""
echo "Topic Switching: < 500ms"
echo "Article Opening: < 300ms"
echo "Content Loading: < 1000ms"
echo "Section Expansion: < 200ms"
echo "Navigation: < 300ms"
echo ""

echo "========================================"
echo "Test Result Location"
echo "========================================"
echo ""
echo "Full results saved at:"
find ~/Library/Developer/Xcode/DerivedData/Argus-*/Logs/Test -name "*.xcresult" -mtime -1 -type d 2>/dev/null | head -1

echo ""
echo "To open in Xcode:"
echo "1. Open Xcode"
echo "2. Window > Organizer > Reports"
echo "3. Or double-click the .xcresult file"
echo ""

echo "========================================"
echo "Next Steps Based on Results"
echo "========================================"
echo ""
echo "If any metric exceeds its target:"
echo ""
echo -e "${YELLOW}Topic Switching > 500ms:${NC}"
echo "  • Optimize database queries"
echo "  • Add query result caching"
echo "  • Pre-fetch topic data"
echo ""
echo -e "${YELLOW}Article Opening > 300ms:${NC}"
echo "  • Optimize initial data load"
echo "  • Defer non-critical operations"
echo "  • Pre-warm view components"
echo ""
echo -e "${YELLOW}Content Loading > 1000ms:${NC}"
echo "  • Implement progressive loading"
echo "  • Optimize text rendering"
echo "  • Cache processed content"
echo ""
echo -e "${YELLOW}Section Expansion > 200ms:${NC}"
echo "  • Pre-render section content"
echo "  • Optimize animation performance"
echo "  • Reduce layout calculations"
echo ""

echo "========================================"
echo "Test log saved to: test_output.log"
echo "========================================"
