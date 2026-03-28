#!/bin/bash
# run-tests.sh — Run project tests and output structured results
# Called by the build verification hook or manually by Claude.
#
# Receives JSON on stdin: { "tool_input": { "file_path": "/path/to/file" } }
# Detects project type and runs the appropriate test suite.
#
# Output: JSON with test results for Claude to act on.
# Exit: 0 = all passed, 1 = failures found, 2 = couldn't run tests

set -uo pipefail

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .file_path // empty' 2>/dev/null)

if [ -z "$FILE_PATH" ]; then
    # Can also be called with file path as argument
    FILE_PATH="${1:-}"
fi

if [ -z "$FILE_PATH" ]; then
    exit 0
fi

# --- Find project root ---
find_up() {
    local dir="$1" marker="$2"
    while [ "$dir" != "/" ]; do
        if [ -e "$dir/$marker" ]; then echo "$dir"; return 0; fi
        dir="$(dirname "$dir")"
    done
    return 1
}

PROJECT_ROOT=$(find_up "$(dirname "$FILE_PATH")" "package.json") || exit 0
PROJECT_NAME=$(basename "$PROJECT_ROOT")

# --- Detect test framework ---
HAS_PLAYWRIGHT=false
HAS_JEST=false
HAS_VITEST=false
TEST_CMD=""

if [ -f "$PROJECT_ROOT/playwright.config.ts" ] || [ -f "$PROJECT_ROOT/playwright.config.js" ]; then
    HAS_PLAYWRIGHT=true
fi

cd "$PROJECT_ROOT"

if grep -q '"jest"' package.json 2>/dev/null || [ -f "jest.config.ts" ] || [ -f "jest.config.js" ]; then
    HAS_JEST=true
fi

if grep -q '"vitest"' package.json 2>/dev/null || [ -f "vitest.config.ts" ]; then
    HAS_VITEST=true
fi

# --- Determine what to run based on what changed ---
EXT="${FILE_PATH##*.}"
RELATIVE_PATH="${FILE_PATH#$PROJECT_ROOT/}"

# Skip test runs for non-source files
case "$EXT" in
    md|json|yml|yaml|css|scss|png|jpg|svg) exit 0 ;;
esac

# --- Run type check first (fast) ---
if [ -f "tsconfig.json" ] && ([ "$EXT" = "ts" ] || [ "$EXT" = "tsx" ]); then
    TSC_OUTPUT=$(npx tsc --noEmit 2>&1) || true
    if echo "$TSC_OUTPUT" | grep -q "error TS"; then
        ERROR_COUNT=$(echo "$TSC_OUTPUT" | grep -c "error TS" || true)
        ERRORS=$(echo "$TSC_OUTPUT" | grep "error TS" | head -10 | sed 's/"/\\"/g' | tr '\n' '|')
        cat << ENDJSON
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "❌ TypeScript: $ERROR_COUNT error(s). Fix type errors before running tests.\\nErrors:\\n$(echo "$ERRORS" | tr '|' '\n')"
  }
}
ENDJSON
        exit 1
    fi
fi

# --- Run Playwright E2E if available and a route/handler/middleware was edited ---
if [ "$HAS_PLAYWRIGHT" = "true" ]; then
    # Only auto-run E2E for backend source changes (routes, handlers, middleware, store)
    SHOULD_RUN_E2E=false
    case "$RELATIVE_PATH" in
        src/routes/*|src/handlers/*|src/middleware/*|src/store.*|src/index.*|e2e/*)
            SHOULD_RUN_E2E=true ;;
    esac

    if [ "$SHOULD_RUN_E2E" = "true" ]; then
        E2E_OUTPUT=$(npx playwright test --reporter=line 2>&1) || true
        E2E_EXIT=$?

        # Parse results
        PASSED=$(echo "$E2E_OUTPUT" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' || echo "0")
        FAILED=$(echo "$E2E_OUTPUT" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+' || echo "0")
        TOTAL=$((PASSED + FAILED))

        if [ "$FAILED" = "0" ] && [ "$PASSED" != "0" ]; then
            cat << ENDJSON
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "✅ E2E Tests: $PASSED/$TOTAL passed"
  }
}
ENDJSON
            exit 0
        elif [ "$FAILED" != "0" ]; then
            # Extract failing test names and errors
            FAIL_DETAILS=$(echo "$E2E_OUTPUT" | grep -A 2 "✘\|FAILED\|Error:" | head -30 | sed 's/"/\\"/g' | tr '\n' '|')
            cat << ENDJSON
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "❌ E2E Tests: $FAILED/$TOTAL failed\\n\\nFailing tests:\\n$(echo "$FAIL_DETAILS" | tr '|' '\n')"
  }
}
ENDJSON
            exit 1
        fi
    fi
fi

# --- Run Jest unit tests if available ---
if [ "$HAS_JEST" = "true" ]; then
    # Run related tests only (based on changed file)
    JEST_OUTPUT=$(npx jest --passWithNoTests --findRelatedTests "$FILE_PATH" --no-coverage 2>&1) || true

    if echo "$JEST_OUTPUT" | grep -q "Tests:.*failed"; then
        FAIL_INFO=$(echo "$JEST_OUTPUT" | grep -E "FAIL|●|Tests:" | head -15 | sed 's/"/\\"/g' | tr '\n' '|')
        cat << ENDJSON
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "❌ Jest: tests failed\\n$(echo "$FAIL_INFO" | tr '|' '\n')"
  }
}
ENDJSON
        exit 1
    elif echo "$JEST_OUTPUT" | grep -q "Tests:.*passed"; then
        PASS_COUNT=$(echo "$JEST_OUTPUT" | grep -oE '[0-9]+ passed' | head -1 || echo "?")
        cat << ENDJSON
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "✅ Jest: $PASS_COUNT"
  }
}
ENDJSON
        exit 0
    fi
fi

# --- Vitest ---
if [ "$HAS_VITEST" = "true" ]; then
    VITEST_OUTPUT=$(npx vitest run --reporter=verbose 2>&1) || true
    if echo "$VITEST_OUTPUT" | grep -q "Tests.*failed"; then
        FAIL_INFO=$(echo "$VITEST_OUTPUT" | grep -E "FAIL|×|Tests" | head -15 | sed 's/"/\\"/g' | tr '\n' '|')
        cat << ENDJSON
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "❌ Vitest: tests failed\\n$(echo "$FAIL_INFO" | tr '|' '\n')"
  }
}
ENDJSON
        exit 1
    fi
fi

# No tests to run for this file
exit 0
