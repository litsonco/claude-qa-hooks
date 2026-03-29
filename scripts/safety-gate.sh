#!/bin/bash
# safety-gate.sh — PreToolUse hook that blocks destructive Bash commands
#
# Runs BEFORE Claude executes a Bash command. Reads the proposed command
# from stdin JSON and checks it against a blocklist of dangerous patterns.
#
# If a dangerous command is detected, exits non-zero to BLOCK execution
# and returns a message explaining why.
#
# Receives JSON on stdin:
#   { "tool_name": "Bash", "tool_input": { "command": "rm -rf /" } }
#
# Exit codes: 0 = safe (allow), 1 = blocked (dangerous command detected)
#
# Environment:
#   CLAUDE_SKIP_SAFETY_GATE=true   Disable this hook temporarily

set -uo pipefail

if [ "${CLAUDE_SKIP_SAFETY_GATE:-}" = "true" ]; then
    exit 0
fi

# QA log location
QA_LOG="${CLAUDE_QA_LOG:-$HOME/.claude/qa-log.jsonl}"

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
    exit 0
fi

# Helper: emit block message
block() {
    local reason="$1"
    jq -n --arg reason "$reason" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",decision:"block",additionalContext:$reason}}'

    # Log the block
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    jq -n --arg ts "$timestamp" --arg cmd "$COMMAND" --arg reason "$reason" \
      '{timestamp:$ts,hook:"safety-gate",command:$cmd,action:"blocked",reason:$reason}' \
      >> "$QA_LOG" 2>/dev/null || true

    exit 1
}

# --- Destructive file operations ---
# rm -rf with broad targets (/, ~, $HOME, .)
if echo "$COMMAND" | grep -qE 'rm\s+(-[a-zA-Z]*f[a-zA-Z]*\s+|--force\s+)*(\/|~|\$HOME|\.\s|\.\/\s)'; then
    block "BLOCKED: Destructive rm command detected. This could delete critical files. Please specify exact paths."
fi

# rm -rf without a specific target (bare rm -rf)
if echo "$COMMAND" | grep -qE '^\s*rm\s+-rf\s*$'; then
    block "BLOCKED: rm -rf with no target. Specify the exact path to delete."
fi

# --- Destructive git operations ---
if echo "$COMMAND" | grep -qE 'git\s+push\s+.*--force\s'; then
    block "BLOCKED: git push --force can overwrite remote history. Use --force-with-lease for safer force pushes, or confirm with the user first."
fi

if echo "$COMMAND" | grep -qE 'git\s+reset\s+--hard'; then
    block "BLOCKED: git reset --hard discards uncommitted changes permanently. Stash changes first (git stash) or confirm with the user."
fi

if echo "$COMMAND" | grep -qE 'git\s+clean\s+-[a-zA-Z]*f'; then
    block "BLOCKED: git clean -f permanently deletes untracked files. Use git clean -n (dry run) first."
fi

if echo "$COMMAND" | grep -qE 'git\s+branch\s+-D\s+main|git\s+branch\s+-D\s+master'; then
    block "BLOCKED: Deleting main/master branch. This is almost certainly not what you want."
fi

# --- Database destruction ---
if echo "$COMMAND" | grep -qiE 'DROP\s+(TABLE|DATABASE|SCHEMA)\s'; then
    block "BLOCKED: DROP TABLE/DATABASE detected. This permanently destroys data. Confirm with the user first."
fi

if echo "$COMMAND" | grep -qiE 'TRUNCATE\s+TABLE\s'; then
    block "BLOCKED: TRUNCATE TABLE detected. This permanently deletes all rows. Confirm with the user first."
fi

if echo "$COMMAND" | grep -qiE 'DELETE\s+FROM\s+\w+\s*$|DELETE\s+FROM\s+\w+\s*;'; then
    block "BLOCKED: DELETE FROM without WHERE clause. This deletes all rows in the table."
fi

# --- Process killing ---
if echo "$COMMAND" | grep -qE 'kill\s+-9\s+1\b|kill\s+-KILL\s+1\b'; then
    block "BLOCKED: Killing PID 1 (init/systemd). This could crash the system."
fi

if echo "$COMMAND" | grep -qE 'killall\s+-9\s'; then
    block "BLOCKED: killall -9 force-kills processes without cleanup. Use regular kill first."
fi

# --- Dangerous downloads/pipes ---
if echo "$COMMAND" | grep -qE 'curl\s.*\|\s*sudo\s+bash|wget\s.*\|\s*sudo\s+bash'; then
    block "BLOCKED: Piping downloaded script to sudo bash. Download and inspect the script first."
fi

# --- Disk/filesystem destruction ---
if echo "$COMMAND" | grep -qE 'mkfs\.|format\s+'; then
    block "BLOCKED: Filesystem format command detected. This destroys all data on the target device."
fi

if echo "$COMMAND" | grep -qE 'dd\s+.*of=/dev/'; then
    block "BLOCKED: dd writing to a device. This can overwrite disk data irreversibly."
fi

# --- Environment/config destruction ---
if echo "$COMMAND" | grep -qE 'unset\s+(PATH|HOME|USER)\b'; then
    block "BLOCKED: Unsetting critical environment variable (PATH/HOME/USER)."
fi

# Command passed all checks — allow it
exit 0
