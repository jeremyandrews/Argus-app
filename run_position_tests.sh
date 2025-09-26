#!/bin/bash

# Position Counter Validation Test Runner for Argus App
# This script runs the specific position counter tests to verify the sort order fix

echo "========================================"
echo "Argus Position Counter Validation Tests"
echo "========================================"
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo "🎯 Running position counter validation tests..."
echo ""
echo "These tests verify:"
echo ""
echo -e "${BLUE}1. Top Article Position Counter${NC}"
echo "   - Clicking top article shows '1 of X'"
echo "   - Verifies sort order consistency"
echo ""
echo -e "${BLUE}2. Position Counter Navigation${NC}"
echo "   - Navigation updates position correctly"
echo "   - Forward/back navigation works properly"
echo ""
echo -e "${BLUE}3. Position Counter Consistency${NC}"
echo "   - Multiple articles from different positions"
echo "   - Consistent position numbering"
echo ""

echo "========================================"
echo "Running Position Counter Tests..."
echo "========================================"
echo ""

# Run the specific position counter tests
xcodebuild test \
    -scheme Argus \
    -destination 'platform=iOS Simulator,id=DD439625-C73D-4D1A-9E8F-E99ADEE93CA0' \
    -only-testing:ArgusUITests/ArticleNavigationPerformanceTests/testTopArticlePositionCounter \
    -only-testing:ArgusUITests/ArticleNavigationPerformanceTests/testPositionCounterNavigation \
    -only-testing:ArgusUITests/ArticleNavigationPerformanceTests/testPositionCounterConsistency \
    2>&1 | tee position_test_output.log

echo ""
echo "========================================"
echo "Position Test Results Summary"
echo "========================================"
echo ""

# Extract and display test results
if grep -q "Test Suite 'Selected tests' passed" position_test_output.log; then
    echo -e "${GREEN}✅ All position counter tests PASSED!${NC}"
    echo ""
    echo "The sort order consistency fix is working correctly:"
    echo "• Top articles show '1 of X' position"
    echo "• Navigation updates positions properly"
    echo "• Position counters are consistent across articles"
else
    echo -e "${RED}❌ Some position counter tests FAILED${NC}"
    echo ""
    echo "Check the detailed output above for specific failures."
    echo "Common issues to investigate:"
    echo "• Sort order mismatch between list and detail views"
    echo "• Position calculation errors"
    echo "• Navigation dataset inconsistencies"
fi

echo ""
echo "========================================"
echo "Detailed Test Output"
echo "========================================"
echo ""
echo "Full test log saved to: position_test_output.log"
echo ""
echo "To view detailed results in Xcode:"
echo "1. Open Xcode"
echo "2. Press ⌘+9 to open Report Navigator"
echo "3. Find the latest test run"
echo "4. Expand 'ArticleNavigationPerformanceTests'"
echo "5. Check each position counter test result"
echo ""

# Show any test failures in detail
if grep -q "failed" position_test_output.log; then
    echo -e "${YELLOW}Test Failure Details:${NC}"
    grep -A 5 -B 5 "failed\|error\|assertion" position_test_output.log | head -20
fi

echo "========================================"
