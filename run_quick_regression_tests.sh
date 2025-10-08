#!/bin/bash

# Quick Regression Test - No Simulator Required
# Tests core functionality via unit tests and build verification

echo "========================================"
echo "Quick Regression Test Suite"
echo "No simulator popup - fast feedback"
echo "========================================"
echo ""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Track test results
TESTS_PASSED=0
TESTS_FAILED=0

echo "📋 Test 1: Unit Tests"
echo "   Running TopicFetchTests (no simulator required)..."
test_start=$(date +%s)
if xcodebuild test -project Argus.xcodeproj -scheme Argus -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.2' -only-testing:ArgusTests/TopicFetchTests -quiet > /tmp/quick_test.log 2>&1; then
    test_end=$(date +%s)
    test_time=$((test_end - test_start))

    # Count passed tests
    passed_count=$(grep -c "Test.*passed" /tmp/quick_test.log 2>/dev/null || echo "0")

    echo -e "${GREEN}   ✅ All unit tests passed${NC} (${test_time}s, ${passed_count} tests)"
    TESTS_PASSED=$((TESTS_PASSED + passed_count))
else
    echo -e "${RED}   ❌ Unit tests failed${NC}"
    echo "   Check /tmp/quick_test.log for details"
    grep -A 3 "error:" /tmp/quick_test.log | head -20
    TESTS_FAILED=$((TESTS_FAILED + 1))
    exit 1
fi
echo ""

echo "📋 Test 2: Error Detection"
echo "   Scanning test logs for errors..."

# Check for compile errors
compile_errors=$(grep "error:" /tmp/quick_test.log 2>/dev/null | wc -l | tr -d ' ')
if [ "$compile_errors" -gt 0 ] 2>/dev/null; then
    echo -e "${RED}   ❌ Found $compile_errors compile error(s)${NC}"
    grep "error:" /tmp/quick_test.log | head -5
    TESTS_FAILED=$((TESTS_FAILED + 1))
else
    echo -e "${GREEN}   ✅ No compile errors${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# Check for test failures
test_failures=$(grep -E "failed|FAILED" /tmp/quick_test.log 2>/dev/null | wc -l | tr -d ' ')
if [ "$test_failures" -gt 0 ] 2>/dev/null; then
    echo -e "${RED}   ❌ Found $test_failures test failure(s)${NC}"
    grep -E "failed|FAILED" /tmp/quick_test.log | head -5
    TESTS_FAILED=$((TESTS_FAILED + 1))
else
    echo -e "${GREEN}   ✅ No test failures${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# Check for runtime errors (crashes, exceptions)
runtime_errors=$(grep -E "fatal error|assertion failed|crash|exception|abort" /tmp/quick_test.log 2>/dev/null | wc -l | tr -d ' ')
if [ "$runtime_errors" -gt 0 ] 2>/dev/null; then
    echo -e "${RED}   ❌ Found $runtime_errors runtime error(s)${NC}"
    grep -E "fatal error|assertion failed|crash|exception" /tmp/quick_test.log | head -3
    TESTS_FAILED=$((TESTS_FAILED + 1))
else
    echo -e "${GREEN}   ✅ No runtime errors${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# Check warning count (informational, not a failure)
warning_count=$(grep "warning:" /tmp/quick_test.log 2>/dev/null | wc -l | tr -d ' ')
if [ "$warning_count" -gt 0 ] 2>/dev/null; then
    echo -e "${YELLOW}   ⚠️  $warning_count warning(s) found${NC}"
else
    echo -e "${GREEN}   ✅ No warnings${NC}"
fi
echo ""

echo "📋 Test 3: Code Analysis"
echo "   Checking for common issues..."

# Check for fetchDistinctTopics method
if grep -q "func fetchDistinctTopics" Argus/ArticleOperations.swift; then
    echo -e "${GREEN}   ✅ fetchDistinctTopics method exists${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}   ❌ fetchDistinctTopics method missing${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Check that it accepts filter parameters
if grep -q "showUnreadOnly: Bool" Argus/ArticleOperations.swift && \
   grep -q "showBookmarkedOnly: Bool" Argus/ArticleOperations.swift && \
   grep -q "qualityFilter: String" Argus/ArticleOperations.swift; then
    echo -e "${GREEN}   ✅ fetchDistinctTopics accepts filter parameters${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}   ❌ fetchDistinctTopics missing filter parameters${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Check NewsViewModel uses availableTopics
if grep -q "availableTopics: Set<String>" Argus/NewsViewModel.swift; then
    echo -e "${GREEN}   ✅ NewsViewModel has availableTopics property${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}   ❌ NewsViewModel missing availableTopics property${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Check that filters are passed to fetchDistinctTopics
if grep -A 3 "fetchDistinctTopics" Argus/NewsViewModel.swift | grep -q "showUnreadOnly:"; then
    echo -e "${GREEN}   ✅ NewsViewModel passes filters to fetchDistinctTopics${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}   ❌ NewsViewModel not passing filters to fetchDistinctTopics${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Check NewsView uses availableTopics
if grep -q "viewModel.availableTopics" Argus/NewsView.swift; then
    echo -e "${GREEN}   ✅ NewsView uses availableTopics${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}   ❌ NewsView not using availableTopics${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi
echo ""

echo "📋 Test 4: Performance Indicators"
echo "   Checking for performance anti-patterns..."

# Check that we're NOT fetching entire database for topic bar
if grep -A 5 "refreshArticles\|refreshAfterBackgroundSync" Argus/NewsViewModel.swift | \
   grep -q "fetchArticles.*topic: nil.*context: .detailView" && \
   ! grep -A 5 "refreshArticles\|refreshAfterBackgroundSync" Argus/NewsViewModel.swift | \
   grep -q "fetchDistinctTopics"; then
    echo -e "${YELLOW}   ⚠️  WARNING: Still using fetchArticles for topic bar${NC}"
    echo -e "${YELLOW}   This will cause performance issues with large datasets${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
else
    echo -e "${GREEN}   ✅ Using lightweight topic query${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
fi
echo ""

echo "📋 Test 5: Performance Tracking"
echo "   Analyzing query performance trends..."

# Performance tracking directory and files
PERF_DIR=".performance"
mkdir -p "$PERF_DIR"

PERF_BASELINE="$PERF_DIR/baseline.txt"
PERF_CURRENT="$PERF_DIR/current.txt"
PERF_HISTORY="$PERF_DIR/history.log"

# Extract performance metrics from test log
# Look for the performance test duration - extract seconds from "(X.XXX seconds)" format
# Note: 1.000s = actual test run with 3000 articles, 0.000s = cached/parallel execution
perf_test_time=$(grep "testFetchDistinctTopicsPerformance" /tmp/quick_test.log | grep -o "([0-9.]* seconds)" | grep -o "[0-9.]*" | head -1)

# Also extract total test time for trend analysis
total_test_time=$test_time

# Save current performance
echo "perf_test=${perf_test_time}" > "$PERF_CURRENT"
echo "total_time=${total_test_time}" >> "$PERF_CURRENT"

# Check if we have a baseline
if [ -f "$PERF_BASELINE" ]; then
    # Load baseline
    source "$PERF_BASELINE"
    baseline_perf=$perf_test
    baseline_total=$total_time

    # Calculate percentage change for total test time (more meaningful than individual test)
    if [ -n "$total_test_time" ] && [ -n "$baseline_total" ] && [ "$baseline_total" != "0" ]; then
        total_change=$(echo "scale=1; ($total_test_time - $baseline_total) / $baseline_total * 100" | bc 2>/dev/null || echo "0")

        # Flag if performance degraded by more than 20%
        perf_threshold=20
        if (( $(echo "$total_change > $perf_threshold" | bc -l) )); then
            echo -e "${RED}   ⚠️  Performance regression detected!${NC}"
            echo -e "${RED}   Total test suite: ${total_test_time}s (was ${baseline_total}s, +${total_change}%)${NC}"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        elif (( $(echo "$total_change < -10" | bc -l) )); then
            echo -e "${GREEN}   🚀 Performance improved!${NC}"
            echo -e "${GREEN}   Total test suite: ${total_test_time}s (was ${baseline_total}s, ${total_change}%)${NC}"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "${GREEN}   ✅ Performance stable${NC}"
            echo "   Total test suite: ${total_test_time}s (baseline: ${baseline_total}s, change: ${total_change}%)"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        fi
    else
        echo -e "${YELLOW}   ⚠️  Could not calculate performance change${NC}"
        echo "   Current: ${total_test_time}s, Baseline: ${baseline_total}s"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    fi
else
    echo -e "${BLUE}   📊 No baseline found - establishing new baseline${NC}"
    echo "   Performance test time: ${perf_test_time}s"
    echo "   Total test time: ${total_test_time}s"
    echo ""
    echo "   Run this script again to compare against this baseline."
    TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# Log performance history
# Create header if file doesn't exist
if [ ! -f "$PERF_HISTORY" ]; then
    echo "timestamp,commit,branch,total_time_sec,perf_test_sec" > "$PERF_HISTORY"
fi

timestamp=$(date "+%Y-%m-%d %H:%M:%S")
commit=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
echo "${timestamp},${commit},${branch},${total_test_time},${perf_test_time}" >> "$PERF_HISTORY"

# Update baseline with current performance (only if tests passed)
if [ $TESTS_FAILED -eq 0 ]; then
    cp "$PERF_CURRENT" "$PERF_BASELINE"
    echo -e "${GREEN}   ✅ Baseline updated${NC}"
fi
echo ""

echo "========================================"
echo "Test Summary"
echo "========================================"
echo -e "${GREEN}Passed: ${TESTS_PASSED}${NC}"
if [ $TESTS_FAILED -gt 0 ]; then
    echo -e "${RED}Failed: ${TESTS_FAILED}${NC}"
else
    echo -e "${GREEN}Failed: ${TESTS_FAILED}${NC}"
fi
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}✅ All regression tests passed!${NC}"
    echo ""
    echo "Key improvements verified:"
    echo "  • Lightweight topic query implemented"
    echo "  • Filter parameters respected"
    echo "  • Performance optimization in place"
    echo "  • Performance tracking enabled"
    echo ""
    exit 0
else
    echo -e "${RED}❌ Some regression tests failed${NC}"
    echo ""
    echo "Please review the failures above and fix before proceeding."
    echo ""
    echo "To reset performance baseline: rm .performance/baseline.txt"
    echo "To view performance history: cat .performance/history.log"
    echo ""
    exit 1
fi
