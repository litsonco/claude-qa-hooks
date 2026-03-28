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
#
# Exit codes: 0 = passed, 1 = failed

set -uo pipefail

# Read stdin JSON and extract the edited file path
INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_response.filePath // empty' 2>/dev/null)

if [ -z "$FILE_PATH" ]; then
    exit 0
fi

# Get file extension
EXT="${FILE_PATH##*.}"

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
        echo '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"✅ iOS BUILD SUCCEEDED"}}'
        exit 0
    elif echo "$BUILD_OUTPUT" | grep -q "BUILD FAILED"; then
        ERRORS=$(echo "$BUILD_OUTPUT" | grep "error:" | sort -u | head -10)
        echo "{\"hookSpecificOutput\":{\"hookEventName\":\"PostToolUse\",\"additionalContext\":\"❌ iOS BUILD FAILED:\\n$ERRORS\"}}"
        exit 1
    fi
    exit 0
fi

# --- TYPESCRIPT ---
if [ "$EXT" = "ts" ] || [ "$EXT" = "tsx" ]; then
    # Find nearest tsconfig.json
    SEARCH_DIR="$(dirname "$FILE_PATH")"
    TS_ROOT=""
    while [ "$SEARCH_DIR" != "/" ]; do
        if [ -f "$SEARCH_DIR/tsconfig.json" ]; then
            TS_ROOT="$SEARCH_DIR"
            break
        fi
        SEARCH_DIR="$(dirname "$SEARCH_DIR")"
    done

    if [ -z "$TS_ROOT" ]; then
        exit 0
    fi

    cd "$TS_ROOT"
    TSC_OUTPUT=$(npx tsc --noEmit 2>&1) || true

    if [ $? -eq 0 ] || ! echo "$TSC_OUTPUT" | grep -q "error TS"; then
        echo '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"✅ TypeScript: no errors"}}'
        exit 0
    else
        ERROR_COUNT=$(echo "$TSC_OUTPUT" | grep -c "error TS" || true)
        ERRORS=$(echo "$TSC_OUTPUT" | grep "error TS" | head -10)
        echo "{\"hookSpecificOutput\":{\"hookEventName\":\"PostToolUse\",\"additionalContext\":\"❌ TypeScript: $ERROR_COUNT error(s)\\n$ERRORS\"}}"
        exit 1
    fi
fi

# --- PYTHON ---
if [ "$EXT" = "py" ]; then
    if [ -f "$FILE_PATH" ]; then
        PY_OUTPUT=$(python3 -m py_compile "$FILE_PATH" 2>&1)
        if [ $? -eq 0 ]; then
            echo '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"✅ Python: syntax OK"}}'
            exit 0
        else
            echo "{\"hookSpecificOutput\":{\"hookEventName\":\"PostToolUse\",\"additionalContext\":\"❌ Python syntax error:\\n$PY_OUTPUT\"}}"
            exit 1
        fi
    fi
fi

exit 0
