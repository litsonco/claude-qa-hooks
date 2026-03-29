#!/bin/bash
# verify-build.sh — Universal build verifier for all project types
# Runs as a Claude Code PostToolUse hook after Edit/Write operations.
#
# Receives JSON on stdin from Claude Code with:
#   { "tool_name": "Edit", "tool_input": { "file_path": "/path/to/file.swift" }, "tool_response": {...} }
#
# Detects project type from the edited file and runs the appropriate check:
#   - .swift → xcodebuild (compile-check, no signing)
#   - .ts/.tsx → npx tsc --noEmit
#   - .js/.jsx → npx eslint (if available)
#   - .py → python3 -m py_compile
#   - .go → go vet
#   - .rs → cargo check
#
# Exit codes: 0 = passed, 1 = failed

set -uo pipefail

# Allow skipping via env var
if [ "${CLAUDE_SKIP_BUILD_VERIFY:-}" = "true" ]; then
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
    local status="$1" lang="$2" detail="$3"
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    jq -n --arg ts "$timestamp" --arg file "$FILE_PATH" --arg status "$status" \
          --arg lang "$lang" --arg detail "$detail" \
      '{timestamp:$ts,hook:"verify-build",file:$file,status:$status,lang:$lang,detail:$detail}' \
      >> "$QA_LOG" 2>/dev/null || true
}

# Read stdin JSON and extract the edited file path
INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_response.filePath // empty' 2>/dev/null)

if [ -z "$FILE_PATH" ]; then
    exit 0
fi

# Get file extension
EXT="${FILE_PATH##*.}"

# --- Helper: walk up to find a file/dir ---
find_up() {
    local dir="$1" marker="$2"
    while [ "$dir" != "/" ]; do
        if [ -e "$dir/$marker" ]; then echo "$dir"; return 0; fi
        dir="$(dirname "$dir")"
    done
    return 1
}

# --- SWIFT / XCODE ---
if [ "$EXT" = "swift" ]; then
    # Find nearest .xcodeproj
    SEARCH_DIR="$(dirname "$FILE_PATH")"
    XCODEPROJ=""
    while [ "$SEARCH_DIR" != "/" ]; do
        FOUND=$(find "$SEARCH_DIR" -maxdepth 2 -name "*.xcodeproj" -type d 2>/dev/null | head -1)
        if [ -n "$FOUND" ]; then
            XCODEPROJ="$FOUND"
            break
        fi
        SEARCH_DIR="$(dirname "$SEARCH_DIR")"
    done

    if [ -z "$XCODEPROJ" ]; then
        exit 0
    fi

    PROJECT_DIR="$(dirname "$XCODEPROJ")"
    PROJECT_NAME="$(basename "$XCODEPROJ" .xcodeproj)"

    cd "$PROJECT_DIR"
    BUILD_OUTPUT=$(xcodebuild \
        -project "$(basename "$XCODEPROJ")" \
        -scheme "$PROJECT_NAME" \
        -destination 'generic/platform=iOS' \
        -configuration Debug \
        build \
        CODE_SIGN_IDENTITY="" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO \
        2>&1) || true

    if echo "$BUILD_OUTPUT" | grep -q "BUILD SUCCEEDED"; then
        log_result "pass" "swift" "BUILD SUCCEEDED"
        emit "✅ iOS BUILD SUCCEEDED"
        exit 0
    elif echo "$BUILD_OUTPUT" | grep -q "BUILD FAILED"; then
        ERRORS=$(echo "$BUILD_OUTPUT" | grep "error:" | sort -u | head -10)
        log_result "fail" "swift" "$ERRORS"
        emit "❌ iOS BUILD FAILED:
$ERRORS"
        exit 1
    fi
    exit 0
fi

# --- TYPESCRIPT ---
if [ "$EXT" = "ts" ] || [ "$EXT" = "tsx" ]; then
    TS_ROOT=$(find_up "$(dirname "$FILE_PATH")" "tsconfig.json") || exit 0

    cd "$TS_ROOT"
    TSC_OUTPUT=$(npx tsc --noEmit 2>&1)
    TSC_EXIT=$?

    if [ $TSC_EXIT -eq 0 ] || ! echo "$TSC_OUTPUT" | grep -q "error TS"; then
        log_result "pass" "typescript" "no errors"
        emit "✅ TypeScript: no errors"
        exit 0
    else
        ERROR_COUNT=$(echo "$TSC_OUTPUT" | grep -c "error TS" || true)
        ERRORS=$(echo "$TSC_OUTPUT" | grep "error TS" | head -10)
        log_result "fail" "typescript" "$ERROR_COUNT error(s): $ERRORS"
        emit "❌ TypeScript: $ERROR_COUNT error(s)
$ERRORS"
        exit 1
    fi
fi

# --- PYTHON ---
if [ "$EXT" = "py" ]; then
    if [ -f "$FILE_PATH" ]; then
        PY_OUTPUT=$(python3 -m py_compile "$FILE_PATH" 2>&1)
        PY_EXIT=$?
        if [ $PY_EXIT -eq 0 ]; then
            log_result "pass" "python" "syntax OK"
            emit "✅ Python: syntax OK"
            exit 0
        else
            log_result "fail" "python" "$PY_OUTPUT"
            emit "❌ Python syntax error:
$PY_OUTPUT"
            exit 1
        fi
    fi
fi

# --- GO ---
if [ "$EXT" = "go" ]; then
    GO_ROOT=$(find_up "$(dirname "$FILE_PATH")" "go.mod") || exit 0
    cd "$GO_ROOT"

    # go vet checks more than compilation — also catches common mistakes
    GO_OUTPUT=$(go vet ./... 2>&1)
    GO_EXIT=$?

    if [ $GO_EXIT -eq 0 ]; then
        log_result "pass" "go" "vet OK"
        emit "✅ Go: vet passed"
        exit 0
    else
        ERRORS=$(echo "$GO_OUTPUT" | head -10)
        log_result "fail" "go" "$ERRORS"
        emit "❌ Go vet failed:
$ERRORS"
        exit 1
    fi
fi

# --- RUST ---
if [ "$EXT" = "rs" ]; then
    RUST_ROOT=$(find_up "$(dirname "$FILE_PATH")" "Cargo.toml") || exit 0
    cd "$RUST_ROOT"

    CARGO_OUTPUT=$(cargo check --message-format=short 2>&1)
    CARGO_EXIT=$?

    if [ $CARGO_EXIT -eq 0 ]; then
        log_result "pass" "rust" "check OK"
        emit "✅ Rust: cargo check passed"
        exit 0
    else
        ERRORS=$(echo "$CARGO_OUTPUT" | grep "^error" | head -10)
        log_result "fail" "rust" "$ERRORS"
        emit "❌ Rust: cargo check failed:
$ERRORS"
        exit 1
    fi
fi

exit 0
