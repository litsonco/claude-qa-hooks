#!/bin/bash
# flaky-test-detector.sh — Analyze QA log for flaky tests and repeated failures
#
# Reads ~/.claude/qa-log.jsonl and identifies:
#   - Tests that flip between pass/fail (flaky)
#   - Files with repeated failures (chronic issues)
#   - Overall pass/fail trends
#
# Usage:
#   flaky-test-detector.sh [--days N] [--threshold N] [--json] [--escalate]
#
# Options:
#   --days N        Look back N days (default: 7)
#   --threshold N   Min flips to flag as flaky (default: 3)
#   --json          Output as JSON
#   --escalate      Auto-create GitHub issues for flaky tests via escalate-to-human.sh

set -euo pipefail

QA_LOG="${CLAUDE_QA_LOG:-$HOME/.claude/qa-log.jsonl}"
DAYS=7
THRESHOLD=3
JSON_MODE=false
ESCALATE=false
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"

while [ $# -gt 0 ]; do
    case "$1" in
        --days)      DAYS="$2"; shift 2 ;;
        --threshold) THRESHOLD="$2"; shift 2 ;;
        --json)      JSON_MODE=true; shift ;;
        --escalate)  ESCALATE=true; shift ;;
        --help|-h)
            head -16 "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 2 ;;
    esac
done

if [ ! -f "$QA_LOG" ]; then
    echo "No QA log found at $QA_LOG"
    echo "QA hooks will create this file automatically as they run."
    exit 0
fi

# Calculate cutoff date
if date -v-1d +%s &>/dev/null 2>&1; then
    # macOS date
    CUTOFF=$(date -v-${DAYS}d -u +"%Y-%m-%dT%H:%M:%SZ")
else
    # GNU date
    CUTOFF=$(date -u -d "$DAYS days ago" +"%Y-%m-%dT%H:%M:%SZ")
fi

# --- Flaky test detection ---
# A test is flaky if the same file has both pass and fail results within the window
FLAKY_RESULTS=$(jq -r --arg cutoff "$CUTOFF" '
    select(.timestamp >= $cutoff) |
    select(.hook == "run-tests" or .hook == "verify-build") |
    "\(.file)\t\(.status)"
' "$QA_LOG" 2>/dev/null | sort | uniq -c | sort -rn)

# Find files with both pass AND fail
FLAKY_FILES=$(echo "$FLAKY_RESULTS" | awk '{print $3}' | sort | uniq -d)

# --- Chronic failures ---
# Files that failed more than threshold times
CHRONIC_FAILURES=$(jq -r --arg cutoff "$CUTOFF" '
    select(.timestamp >= $cutoff) |
    select(.status == "fail") |
    .file
' "$QA_LOG" 2>/dev/null | sort | uniq -c | sort -rn | awk -v t="$THRESHOLD" '$1 >= t {print $1, $2}')

# --- Summary stats ---
TOTAL_RUNS=$(jq -r --arg cutoff "$CUTOFF" 'select(.timestamp >= $cutoff) | select(.hook == "run-tests" or .hook == "verify-build") | .status' "$QA_LOG" 2>/dev/null | wc -l | tr -d ' ')
TOTAL_PASS=$(jq -r --arg cutoff "$CUTOFF" 'select(.timestamp >= $cutoff) | select(.status == "pass") | .status' "$QA_LOG" 2>/dev/null | wc -l | tr -d ' ')
TOTAL_FAIL=$(jq -r --arg cutoff "$CUTOFF" 'select(.timestamp >= $cutoff) | select(.status == "fail") | .status' "$QA_LOG" 2>/dev/null | wc -l | tr -d ' ')
ESCALATIONS=$(jq -r --arg cutoff "$CUTOFF" 'select(.timestamp >= $cutoff) | select(.hook == "escalate-to-human") | .file' "$QA_LOG" 2>/dev/null | wc -l | tr -d ' ')

if [ "$JSON_MODE" = "true" ]; then
    FLAKY_JSON="[]"
    if [ -n "$FLAKY_FILES" ]; then
        FLAKY_JSON=$(echo "$FLAKY_FILES" | jq -R -s 'split("\n") | map(select(length > 0))')
    fi
    CHRONIC_JSON="[]"
    if [ -n "$CHRONIC_FAILURES" ]; then
        CHRONIC_JSON=$(echo "$CHRONIC_FAILURES" | awk '{print "{\"count\":" $1 ",\"file\":\"" $2 "\"}"}' | jq -s '.')
    fi

    jq -n --argjson total "$TOTAL_RUNS" --argjson pass "$TOTAL_PASS" \
          --argjson fail "$TOTAL_FAIL" --argjson escalations "$ESCALATIONS" \
          --argjson days "$DAYS" --argjson threshold "$THRESHOLD" \
          --argjson flaky "$FLAKY_JSON" --argjson chronic "$CHRONIC_JSON" \
      '{
        period_days: $days,
        threshold: $threshold,
        summary: {total_runs: $total, passed: $pass, failed: $fail, escalations: $escalations},
        flaky_files: $flaky,
        chronic_failures: $chronic
      }'
    exit 0
fi

# --- Human-readable output ---
echo "📊 QA Flaky Test Report (last $DAYS days)"
echo "================================================"
echo ""
echo "Summary:"
echo "  Total hook runs:  $TOTAL_RUNS"
echo "  Passed:           $TOTAL_PASS"
echo "  Failed:           $TOTAL_FAIL"
echo "  Escalations:      $ESCALATIONS"

if [ -n "$FLAKY_FILES" ]; then
    echo ""
    echo "🔄 Flaky Files (pass + fail within $DAYS days):"
    echo "$FLAKY_FILES" | while read -r file; do
        PASS_COUNT=$(jq -r --arg cutoff "$CUTOFF" --arg file "$file" \
            'select(.timestamp >= $cutoff) | select(.file == $file) | select(.status == "pass") | .file' \
            "$QA_LOG" 2>/dev/null | wc -l | tr -d ' ')
        FAIL_COUNT=$(jq -r --arg cutoff "$CUTOFF" --arg file "$file" \
            'select(.timestamp >= $cutoff) | select(.file == $file) | select(.status == "fail") | .file' \
            "$QA_LOG" 2>/dev/null | wc -l | tr -d ' ')
        echo "  ⚠️  $file  (${PASS_COUNT}x pass, ${FAIL_COUNT}x fail)"
    done
else
    echo ""
    echo "✅ No flaky files detected"
fi

if [ -n "$CHRONIC_FAILURES" ]; then
    echo ""
    echo "🔴 Chronic Failures (≥$THRESHOLD failures in $DAYS days):"
    echo "$CHRONIC_FAILURES" | while read -r count file; do
        echo "  ❌ $file  ($count failures)"
    done
else
    echo ""
    echo "✅ No chronic failures"
fi

echo ""
echo "================================================"

# --- Auto-escalate flaky tests if requested ---
if [ "$ESCALATE" = "true" ] && [ -n "$FLAKY_FILES" ]; then
    echo ""
    echo "📤 Escalating flaky tests..."
    echo "$FLAKY_FILES" | while read -r file; do
        if [ -x "$SCRIPTS_DIR/escalate-to-human.sh" ]; then
            "$SCRIPTS_DIR/escalate-to-human.sh" \
                --error "Flaky test: file has both pass and fail results within $DAYS days" \
                --file "$file" \
                --type "test-failure" \
                --codex "This file has intermittent test failures. Likely causes: race conditions, timing-dependent assertions, shared test state, or external service flakiness."
        fi
    done
fi
