#!/bin/bash
# install.sh — One-line install for Claude Code QA hooks
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/litsonco/claude-qa-hooks/main/install.sh | bash
#
# What it does:
# 1. Copies verify-build.sh, run-tests.sh, audit-e2e-coverage.sh to ~/.claude/scripts/
# 2. Merges hook config into ~/.claude/settings.json (preserves existing settings)
# 3. Makes scripts executable

set -euo pipefail

REPO_URL="https://raw.githubusercontent.com/litsonco/claude-qa-hooks/main"
SCRIPTS_DIR="$HOME/.claude/scripts"
SETTINGS_FILE="$HOME/.claude/settings.json"

echo "🔧 Installing Claude Code QA hooks..."

# Create scripts directory
mkdir -p "$SCRIPTS_DIR"

# Download scripts
echo "  📥 Downloading scripts..."
curl -fsSL "$REPO_URL/scripts/verify-build.sh" -o "$SCRIPTS_DIR/verify-build.sh"
curl -fsSL "$REPO_URL/scripts/run-tests.sh" -o "$SCRIPTS_DIR/run-tests.sh"
curl -fsSL "$REPO_URL/scripts/audit-e2e-coverage.sh" -o "$SCRIPTS_DIR/audit-e2e-coverage.sh"

chmod +x "$SCRIPTS_DIR/verify-build.sh"
chmod +x "$SCRIPTS_DIR/run-tests.sh"
chmod +x "$SCRIPTS_DIR/audit-e2e-coverage.sh"

echo "  ✅ Scripts installed to $SCRIPTS_DIR"

# Merge hooks into settings.json
echo "  📝 Configuring hooks..."

HOOKS_JSON='{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/scripts/verify-build.sh",
            "timeout": 300,
            "statusMessage": "Verifying build..."
          },
          {
            "type": "command",
            "command": "~/.claude/scripts/run-tests.sh",
            "timeout": 120,
            "statusMessage": "Running tests...",
            "if": "Edit(*.ts)|Edit(*.tsx)|Edit(*.js)|Edit(*.jsx)|Write(*.ts)|Write(*.tsx)|Write(*.js)|Write(*.jsx)"
          }
        ]
      }
    ]
  }
}'

if [ -f "$SETTINGS_FILE" ]; then
  # Merge with existing settings (preserves plugins, mcpServers, etc.)
  if command -v jq &>/dev/null; then
    MERGED=$(jq -s '.[0] * .[1]' "$SETTINGS_FILE" <(echo "$HOOKS_JSON"))
    echo "$MERGED" > "$SETTINGS_FILE"
    echo "  ✅ Hooks merged into existing $SETTINGS_FILE"
  else
    echo "  ⚠️  jq not found — cannot auto-merge. Add hooks manually."
    echo "  Copy this into your $SETTINGS_FILE:"
    echo "$HOOKS_JSON"
  fi
else
  # Create new settings file
  mkdir -p "$(dirname "$SETTINGS_FILE")"
  echo "$HOOKS_JSON" > "$SETTINGS_FILE"
  echo "  ✅ Created $SETTINGS_FILE with hooks"
fi

echo ""
echo "🎉 Done! Restart Claude Code for hooks to take effect."
echo ""
echo "What's installed:"
echo "  • verify-build.sh  — Auto type-check Swift/TypeScript/Python after edits"
echo "  • run-tests.sh     — Auto run Playwright/Jest/Vitest on TS/JS edits"
echo "  • audit-e2e-coverage.sh — Check which routes have E2E tests"
echo ""
echo "Run 'audit-e2e-coverage.sh /path/to/project' to check test coverage."
