#!/bin/bash
# run-tests.sh — Run project tests and output structured results
# Called by the build verification hook or manually by Claude.
#
# Receives JSON on stdin: { "tool_input": { "file_path": "/path/to/file" } }
# Detects project type and runs the appropriate test suite.
#
# NOTE: Type-checking is handled by verify-build.sh (runs first in the hook chain).
# This script only runs tests — no duplicate tsc calls.
#
# Output: JSON with test results for Claude to act on.
# Exit: 0 = all passed, 1 = failures found

set -uo pipefail

# Allow skipping via env var
if [ "${CLAUDE_SKIP_TESTS:-}" = "true" ]; then
    exit 0
fi

# QA log location
QA_LOG="${CLAUDE_QA_LOG:-$HOME/.claude/qa-log.jsonl}"

# Helper: emit structured JSON output safely via jq
emit() {
    local ctx="$1"
    jq -n --arg ctx "$ctx" \
      '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$ctx}}'
}

# Helper: append to QA log
log_result() {
    local status="$1" framework="$2" detail="$3"
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    jq -n --arg ts "$timestamp" --arg file "$FILE_PATH" --arg status "$status" \
          --arg fw "$framework" --arg detail "$detail" \
      '{timestamp:$ts,hook:"run-tests",file:$file,status:$status,framework:$fw,detail:$detail}' \
      >> "$QA_LOG" 2>/dev/null || true
}

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

# --- Detect test framework ---
HAS_PLAYWRIGHT=false
HAS_JEST=false
HAS_VITEST=false

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

# --- Run Playwright E2E if available and a route/handler/middleware was edited ---
if [ "$HAS_PLAYWRIGHT" = "true" ]; then
    SHOULD_RUN_E2E=false
    case "$RELATIVE_PATH" in
        src/routes/*|src/handlers/*|src/middleware/*|src/store.*|src/index.*|e2e/*)
            SHOULD_RUN_E2E=true ;;
    esac

    if [ "$SHOULD_RUN_E2E" = "true" ]; then
        # If a specific e2e spec was edited, only run that spec
        if [[ "$RELATIVE_PATH" == e2e/*.spec.* ]]; then
            E2E_OUTPUT=$(npx playwright test "$FILE_PATH" --reporter=line 2>&1) || true
        else
            E2E_OUTPUT=$(npx playwright test --reporter=line 2>&1) || true
        fi

        # Parse results
        PASSED=$(echo "$E2E_OUTPUT" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' || echo "0")
        FAILED=$(echo "$E2E_OUTPUT" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+' || echo "0")
        TOTAL=$((PASSED + FAILED))

        if [ "$FAILED" = "0" ] && [ "$PASSED" != "0" ]; then
            log_result "pass" "playwright" "$PASSED/$TOTAL passed"
            emit "✅ E2E Tests: $PASSED/$TOTAL passed"
            exit 0
        elif [ "$FAILED" != "0" ]; then
            FAIL_DETAILS=$(echo "$E2E_OUTPUT" | grep -A 2 "✘\|FAILED\|Error:" | head -30)
            log_result "fail" "playwright" "$FAILED/$TOTAL failed"
            emit "❌ E2E Tests: $FAILED/$TOTAL failed

Failing tests:
$FAIL_DETAILS"
            exit 1
        fi
    fi
fi

# --- Run Jest unit tests if available ---
if [ "$HAS_JEST" = "true" ]; then
    JEST_OUTPUT=$(npx jest --passWithNoTests --findRelatedTests "$FILE_PATH" --no-coverage 2>&1)
    JEST_EXIT=$?

    if [ $JEST_EXIT -ne 0 ] && echo "$JEST_OUTPUT" | grep -q "Tests:.*failed"; then
        FAIL_INFO=$(echo "$JEST_OUTPUT" | grep -E "FAIL|●|Tests:" | head -15)
        log_result "fail" "jest" "tests failed"
        emit "❌ Jest: tests failed
$FAIL_INFO"
        exit 1
    elif echo "$JEST_OUTPUT" | grep -q "Tests:.*passed"; then
        PASS_COUNT=$(echo "$JEST_OUTPUT" | grep -oE '[0-9]+ passed' | head -1 || echo "?")
        log_result "pass" "jest" "$PASS_COUNT"
        emit "✅ Jest: $PASS_COUNT"
        exit 0
    fi
fi

# --- Vitest (with related file targeting) ---
if [ "$HAS_VITEST" = "true" ]; then
    # Use --related to only run tests affected by the changed file
    VITEST_OUTPUT=$(npx vitest run --reporter=verbose --related "$FILE_PATH" 2>&1)
    VITEST_EXIT=$?

    if [ $VITEST_EXIT -ne 0 ] && echo "$VITEST_OUTPUT" | grep -q "Tests.*failed"; then
        FAIL_INFO=$(echo "$VITEST_OUTPUT" | grep -E "FAIL|×|Tests" | head -15)
        log_result "fail" "vitest" "tests failed"
        emit "❌ Vitest: tests failed
$FAIL_INFO"
        exit 1
    elif echo "$VITEST_OUTPUT" | grep -q "Tests.*passed"; then
        PASS_COUNT=$(echo "$VITEST_OUTPUT" | grep -oE '[0-9]+ passed' | head -1 || echo "?")
        log_result "pass" "vitest" "$PASS_COUNT"
        emit "✅ Vitest: $PASS_COUNT"
        exit 0
    fi
fi

# No tests to run for this file
exit 0
