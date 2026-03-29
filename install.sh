#!/bin/bash
# install.sh — One-line install for Claude Code QA hooks
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/litsonco/claude-qa-hooks/main/install.sh | bash
#
# What it does:
# 1. Copies all scripts to ~/.claude/scripts/
# 2. Merges hook config into ~/.claude/settings.json (APPENDS to existing hooks, never overwrites)
# 3. Makes scripts executable

set -euo pipefail

REPO_URL="https://raw.githubusercontent.com/litsonco/claude-qa-hooks/main"
SCRIPTS_DIR="$HOME/.claude/scripts"
SETTINGS_FILE="$HOME/.claude/settings.json"

echo "Installing Claude Code QA hooks..."

# Create scripts directory
mkdir -p "$SCRIPTS_DIR"

# Download scripts
echo "  Downloading scripts..."
for script in verify-build.sh run-tests.sh audit-e2e-coverage.sh escalate-to-human.sh flaky-test-detector.sh safety-gate.sh weekly-coverage-audit.sh; do
    curl -fsSL "$REPO_URL/scripts/$script" -o "$SCRIPTS_DIR/$script" 2>/dev/null && \
        chmod +x "$SCRIPTS_DIR/$script" && \
        echo "    + $script" || \
        echo "    - $script (not found, skipping)"
done

echo "  Scripts installed to $SCRIPTS_DIR"

# --- Hook definitions ---
# These are the hooks we want to ensure exist in settings.json
VERIFY_HOOK='{
    "type": "command",
    "command": "~/.claude/scripts/verify-build.sh",
    "timeout": 300,
    "statusMessage": "Verifying build..."
}'

TEST_HOOK='{
    "type": "command",
    "command": "~/.claude/scripts/run-tests.sh",
    "timeout": 120,
    "statusMessage": "Running tests...",
    "if": "Edit(*.ts)|Edit(*.tsx)|Edit(*.js)|Edit(*.jsx)|Write(*.ts)|Write(*.tsx)|Write(*.js)|Write(*.jsx)"
}'

SAFETY_HOOK='{
    "type": "command",
    "command": "~/.claude/scripts/safety-gate.sh",
    "timeout": 5,
    "statusMessage": "Safety check..."
}'

# --- Merge hooks into settings.json (append, don't overwrite) ---
echo "  Configuring hooks..."

if ! command -v jq &>/dev/null; then
    echo "  ERROR: jq is required for installation. Install it:"
    echo "    brew install jq    (macOS)"
    echo "    apt install jq     (Linux)"
    exit 1
fi

# Initialize settings file if it doesn't exist
if [ ! -f "$SETTINGS_FILE" ]; then
    mkdir -p "$(dirname "$SETTINGS_FILE")"
    echo '{}' > "$SETTINGS_FILE"
fi

# Read existing settings
EXISTING=$(cat "$SETTINGS_FILE")

# Helper: check if a hook command already exists in a hook array
has_hook() {
    local hook_array="$1" command="$2"
    echo "$hook_array" | jq -e --arg cmd "$command" 'map(select(.command == $cmd)) | length > 0' &>/dev/null
}

# Get or initialize the PostToolUse array
POST_HOOKS=$(echo "$EXISTING" | jq '.hooks.PostToolUse // []')

# Check if we have a matcher entry for Edit|Write
EDIT_WRITE_IDX=$(echo "$POST_HOOKS" | jq 'to_entries | map(select(.value.matcher == "Edit|Write")) | .[0].key // -1')

if [ "$EDIT_WRITE_IDX" = "-1" ]; then
    # No Edit|Write matcher exists — create one with our hooks
    POST_HOOKS=$(echo "$POST_HOOKS" | jq --argjson vh "$VERIFY_HOOK" --argjson th "$TEST_HOOK" \
        '. + [{"matcher": "Edit|Write", "hooks": [$vh, $th]}]')
    echo "    + Added PostToolUse Edit|Write hooks"
else
    # Matcher exists — append hooks that aren't already there
    INNER_HOOKS=$(echo "$POST_HOOKS" | jq --argjson idx "$EDIT_WRITE_IDX" '.[$idx].hooks // []')

    if ! has_hook "$INNER_HOOKS" "~/.claude/scripts/verify-build.sh"; then
        INNER_HOOKS=$(echo "$INNER_HOOKS" | jq --argjson vh "$VERIFY_HOOK" '. + [$vh]')
        echo "    + Added verify-build hook"
    else
        echo "    = verify-build hook already exists"
    fi

    if ! has_hook "$INNER_HOOKS" "~/.claude/scripts/run-tests.sh"; then
        INNER_HOOKS=$(echo "$INNER_HOOKS" | jq --argjson th "$TEST_HOOK" '. + [$th]')
        echo "    + Added run-tests hook"
    else
        echo "    = run-tests hook already exists"
    fi

    POST_HOOKS=$(echo "$POST_HOOKS" | jq --argjson idx "$EDIT_WRITE_IDX" --argjson hooks "$INNER_HOOKS" \
        '.[$idx].hooks = $hooks')
fi

# Get or initialize the PreToolUse array for safety gate
PRE_HOOKS=$(echo "$EXISTING" | jq '.hooks.PreToolUse // []')

BASH_GATE_IDX=$(echo "$PRE_HOOKS" | jq 'to_entries | map(select(.value.matcher == "Bash")) | .[0].key // -1')

if [ "$BASH_GATE_IDX" = "-1" ]; then
    PRE_HOOKS=$(echo "$PRE_HOOKS" | jq --argjson sh "$SAFETY_HOOK" \
        '. + [{"matcher": "Bash", "hooks": [$sh]}]')
    echo "    + Added PreToolUse Bash safety gate"
else
    INNER_PRE=$(echo "$PRE_HOOKS" | jq --argjson idx "$BASH_GATE_IDX" '.[$idx].hooks // []')
    if ! has_hook "$INNER_PRE" "~/.claude/scripts/safety-gate.sh"; then
        INNER_PRE=$(echo "$INNER_PRE" | jq --argjson sh "$SAFETY_HOOK" '. + [$sh]')
        PRE_HOOKS=$(echo "$PRE_HOOKS" | jq --argjson idx "$BASH_GATE_IDX" --argjson hooks "$INNER_PRE" \
            '.[$idx].hooks = $hooks')
        echo "    + Added safety-gate hook"
    else
        echo "    = safety-gate hook already exists"
    fi
fi

# Write back — merge into existing settings (preserving everything else)
MERGED=$(echo "$EXISTING" | jq --argjson post "$POST_HOOKS" --argjson pre "$PRE_HOOKS" \
    '.hooks.PostToolUse = $post | .hooks.PreToolUse = $pre')

echo "$MERGED" > "$SETTINGS_FILE"
echo "  Hooks configured in $SETTINGS_FILE"

echo ""
echo "Done! Restart Claude Code for hooks to take effect."
echo ""
echo "What's installed:"
echo "  Layer 1: verify-build.sh     — Auto type-check Swift/TS/Python/Go/Rust after edits"
echo "  Layer 2: run-tests.sh        — Auto run Playwright/Jest/Vitest on backend changes"
echo "  Layer 3: audit-e2e-coverage.sh — Check which routes have E2E tests"
echo "  Layer 4: escalate-to-human.sh — Create GitHub issues for senior dev review"
echo "  Safety:  safety-gate.sh      — Block destructive Bash commands"
echo "  Analysis: flaky-test-detector.sh — Detect flaky tests from QA log"
echo "  Cron:    weekly-coverage-audit.sh — Weekly coverage report"
echo ""
echo "Quick start:"
echo "  audit-e2e-coverage.sh /path/to/project    # Check test coverage"
echo "  flaky-test-detector.sh --days 7            # Detect flaky tests"
echo ""
echo "Set CLAUDE_QA_REVIEWER=github-handle for auto-assigned escalations."
