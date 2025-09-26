#!/bin/bash

# Performance Test Runner for Argus App with Enhanced Bug Detection
# This script runs the performance tests and provides guidance on reading results
# ENHANCED: Now includes off-by-one bug detection for article navigation

echo "========================================"
echo "Argus Performance Test Runner with Bug Detection"
echo "========================================"
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

echo "🚀 Starting performance tests with enhanced bug detection..."
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
echo -e "${PURPLE}5. Bug Detection Tests (NEW)${NC}"
echo "   - Off-by-one position counter detection"
echo "   - Article count consistency validation"
echo "   - Navigation boundary testing"
echo "   - '1 of 1' vs '1 of 2' discrepancy detection"
echo ""

echo "========================================"
echo "Running Tests..."
echo "========================================"
echo ""

# ENHANCED: Add timeout and performance regression detection
echo "🔍 Running enhanced regression detection tests..."

# Step 1: Test compilation first to catch build issues early
echo "📋 Step 1: Verifying build integrity..."
build_start=$(date +%s)
if ! xcodebuild -project Argus.xcodeproj -scheme Argus build -quiet > build_output.log 2>&1; then
    echo -e "${RED}❌ BUILD FAILED${NC}"
    echo "Build log saved to: build_output.log"
    tail -20 build_output.log
    exit 1
fi
build_end=$(date +%s)
build_time=$((build_end - build_start))
echo -e "${GREEN}✅ Build completed${NC} (${build_time}s)"

# Step 2: Run tests with enhanced monitoring
echo "📋 Step 2: Running performance tests with enhanced monitoring..."
test_start=$(date +%s)

# Enhanced test runner with macOS-compatible timeout and monitoring  
# Use gtimeout if available, otherwise implement manual timeout
if command -v gtimeout >/dev/null 2>&1; then
    gtimeout 300 xcodebuild test \
        -scheme Argus \
        -destination 'platform=iOS Simulator,id=DD439625-C73D-4D1A-9E8F-E99ADEE93CA0' \
        -only-testing:ArgusUITests/PerformanceTestSuite \
        -only-testing:ArgusUITests/ArticleNavigationPerformanceTests \
        2>&1 | tee test_output.log &
else
    # Manual timeout implementation for macOS
    xcodebuild test \
        -scheme Argus \
        -destination 'platform=iOS Simulator,id=DD439625-C73D-4D1A-9E8F-E99ADEE93CA0' \
        -only-testing:ArgusUITests/PerformanceTestSuite \
        -only-testing:ArgusUITests/ArticleNavigationPerformanceTests \
        2>&1 | tee test_output.log &
fi

# Monitor test progress and detect hangs
test_pid=$!
monitor_count=0
while kill -0 $test_pid 2>/dev/null; do
    sleep 5
    monitor_count=$((monitor_count + 1))
    
    # Check for UI lockup indicators every 30 seconds
    if [ $((monitor_count % 6)) -eq 0 ]; then
        echo "🔍 Monitoring test progress... (${monitor_count} * 5s elapsed)"
        
        # Check for signs of UI thread blocking
        if grep -q "UI Tests Runner.*not responding" test_output.log 2>/dev/null; then
            echo -e "${RED}❌ UI LOCKUP DETECTED${NC} - Terminating hanging tests"
            kill -TERM $test_pid 2>/dev/null
            sleep 3
            kill -KILL $test_pid 2>/dev/null
            echo "🚨 PERFORMANCE REGRESSION: UI thread blocking detected"
            break
        fi
    fi
    
    # Hard timeout after 5 minutes
    if [ $monitor_count -gt 60 ]; then
        echo -e "${RED}❌ TEST TIMEOUT${NC} - Tests hanging for 5+ minutes"
        kill -TERM $test_pid 2>/dev/null
        sleep 3  
        kill -KILL $test_pid 2>/dev/null
        echo "🚨 PERFORMANCE REGRESSION: Test execution timeout indicates severe performance issues"
        break
    fi
done

wait $test_pid 2>/dev/null
test_exit_code=$?
test_end=$(date +%s)
test_time=$((test_end - test_start))

echo ""
echo "========================================" 
echo "🔍 ENHANCED REGRESSION ANALYSIS"
echo "========================================"

# Analyze test results for critical regressions
echo "📊 Test Execution Summary:"
echo "   Build Time: ${build_time}s"
echo "   Test Time: ${test_time}s"
echo "   Exit Code: ${test_exit_code}"

# Check for critical performance regressions
if [ $test_time -gt 180 ]; then
    echo -e "${RED}🚨 PERFORMANCE REGRESSION DETECTED${NC}"
    echo "   Test suite took ${test_time}s (normal: < 180s)"
    echo "   This indicates severe performance issues or UI lockups"
fi

# Enhanced bug detection
bug_count=$(grep -c "BUG DETECTED" test_output.log 2>/dev/null || echo "0")
lockup_indicators=$(grep -c -E "(not responding|timeout|hang)" test_output.log 2>/dev/null || echo "0")
counter_issues=$(grep -c "1 of 2" test_output.log 2>/dev/null || echo "0")

echo ""
echo "🐛 Bug Detection Summary:"
echo "   Off-by-one bugs: ${bug_count}"
echo "   UI lockup indicators: ${lockup_indicators}" 
echo "   Counter issues (1 of 2): ${counter_issues}"

# Regression severity assessment
if [ $bug_count -gt 0 ] || [ $lockup_indicators -gt 0 ] || [ $counter_issues -gt 0 ]; then
    echo -e "${RED}❌ CRITICAL REGRESSIONS DETECTED${NC}"
    if [ $lockup_indicators -gt 0 ]; then
        echo -e "${RED}   - UI PERFORMANCE REGRESSION${NC}: App lockups detected"
    fi
    if [ $counter_issues -gt 0 ]; then
        echo -e "${RED}   - COUNTER BUG REGRESSION${NC}: Position counters broken"  
    fi
    if [ $bug_count -gt 0 ]; then
        echo -e "${RED}   - NAVIGATION BUG REGRESSION${NC}: Article navigation issues"
    fi
else
    echo -e "${GREEN}✅ No critical regressions detected${NC}"
fi

# Filter and display relevant test output
grep -E "(Test Case|passed|failed|measured|BUG DETECTED|CONFIRMED|Position counter|Article count)" test_output.log 2>/dev/null | tail -20

echo ""
echo "========================================"
echo "How to Read the Results"
echo "========================================"
echo ""
echo -e "${GREEN}✅ In Xcode (Most Detailed):${NC}"
echo "1. Open Xcode"
echo "2. Press ⌘+9 to open Report Navigator"
echo "3. Find the test run (latest at top)"
echo "4. Click on 'PerformanceTestSuite' and 'ArticleNavigationPerformanceTests'"
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

echo -e "${PURPLE}🐛 Bug Detection Results:${NC}"
echo ""
echo "Look for the following patterns in the test output:"
echo -e "${RED}❌ 'BUG DETECTED'${NC} - Indicates off-by-one errors found"
echo -e "${RED}❌ 'CONFIRMED'${NC} - Bug reproduction confirmed"
echo -e "${YELLOW}⚠️ Position counter${NC} - Shows '1 of 1' vs expected counts"
echo -e "${YELLOW}⚠️ Article count${NC} - Mismatched list vs navigation counts"
echo ""
echo "If bugs are detected, check the full test_output.log for detailed analysis."
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

echo -e "${RED}🐛 If Off-by-One Bugs Are Detected:${NC}"
echo ""
echo -e "${RED}Position Counter Bug ('1 of 1' instead of '1 of 2'):${NC}"
echo "  • Check NewsDetailViewModel.displayPosition/displayTotal logic"
echo "  • Verify originalFilteredArticles vs articles array consistency"
echo "  • Fix useOriginalPosition flag behavior"
echo "  • Ensure fetchCompleteDatasetForNavigation doesn't break counts"
echo ""
echo -e "${RED}Article Count Mismatch:${NC}"
echo "  • Verify list view count matches navigation count"
echo "  • Check if articles disappear during navigation cycles"
echo "  • Look for filtering inconsistencies between list and detail views"
echo ""
echo -e "${RED}Navigation Boundary Issues:${NC}"
echo "  • Test that all list articles are reachable via navigation"
echo "  • Check for articles missing from navigation array"
echo "  • Verify sort order consistency between views"
echo ""

echo "========================================"
echo "Test log saved to: test_output.log"
echo "========================================"
echo ""
echo -e "${PURPLE}🔍 Bug Analysis Commands:${NC}"
echo ""
echo "To analyze detected bugs in detail:"
echo "grep -A 5 -B 5 'BUG DETECTED' test_output.log"
echo "grep -A 3 -B 3 'Position counter' test_output.log"
echo "grep -A 3 -B 3 'Article count' test_output.log"
echo ""
echo "To see all position counter tests:"
echo "grep -E '(testArticleCountConsistency|testNavigateToAllArticles|testFinalArticleScenario|testArticleFilteringConsistency)' test_output.log"
echo ""
echo -e "${PURPLE}📝 Key Bug Indicators to Look For:${NC}"
echo ""
echo "1. Position counter mismatch patterns:"
echo "   • 'Expected: 1 of 2, Found: 1 of 1'"
echo "   • 'Navigation total (1) doesn't match list count (2)'"
echo ""
echo "2. Navigation reach issues:"
echo "   • 'Can only reach X of Y articles'"
echo "   • 'Cannot navigate beyond position X'"
echo ""
echo "3. Article disappearing patterns:"
echo "   • 'Articles lost: X articles during navigation cycles'"
echo "   • 'Final article shows 1 of 0'"
echo ""
echo "4. Filter consistency problems:"
echo "   • 'Article count decreased from X to Y'"
echo "   • 'Articles are disappearing from the list'"
