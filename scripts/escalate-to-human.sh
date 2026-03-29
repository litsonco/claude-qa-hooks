#!/bin/bash
# escalate-to-human.sh — Layer 4: Create a GitHub issue for senior dev review
#
# Called when Claude + Codex both fail to resolve a build/test failure.
# Can also be invoked manually for architecture review or security audit.
#
# Usage:
#   escalate-to-human.sh --error "error output" --file "path/to/file" [options]
#
# Options:
#   --error TEXT        Error output from the hook
#   --file PATH         File that caused the failure
#   --codex TEXT        Codex diagnosis (if available)
#   --type TYPE         Escalation type: build-failure | test-failure | security-review | architecture-review
#   --assignee HANDLE   GitHub handle to assign (default: from CLAUDE_QA_REVIEWER env var)
#   --repo OWNER/REPO   GitHub repo (default: auto-detect from git remote)
#   --dry-run           Print the issue body without creating it
#
# Environment:
#   CLAUDE_QA_REVIEWER  Default assignee GitHub handle
#   CLAUDE_QA_LABELS    Comma-separated labels (default: "qa-hook,needs-human")

set -euo pipefail

# --- Parse arguments ---
ERROR_CONTEXT=""
FILE_PATH=""
CODEX_DIAGNOSIS="Not available (Codex was not invoked or returned no result)"
ESCALATION_TYPE="build-failure"
ASSIGNEE="${CLAUDE_QA_REVIEWER:-}"
REPO=""
DRY_RUN=false
LABELS="${CLAUDE_QA_LABELS:-qa-hook,needs-human}"

while [ $# -gt 0 ]; do
    case "$1" in
        --error)    ERROR_CONTEXT="$2"; shift 2 ;;
        --file)     FILE_PATH="$2"; shift 2 ;;
        --codex)    CODEX_DIAGNOSIS="$2"; shift 2 ;;
        --type)     ESCALATION_TYPE="$2"; shift 2 ;;
        --assignee) ASSIGNEE="$2"; shift 2 ;;
        --repo)     REPO="$2"; shift 2 ;;
        --dry-run)  DRY_RUN=true; shift ;;
        --help|-h)
            head -25 "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 2 ;;
    esac
done

if [ -z "$ERROR_CONTEXT" ] || [ -z "$FILE_PATH" ]; then
    echo "Error: --error and --file are required"
    echo "Run with --help for usage"
    exit 2
fi

# --- Auto-detect repo if not provided ---
if [ -z "$REPO" ]; then
    FILE_DIR="$(dirname "$FILE_PATH")"
    if [ -d "$FILE_DIR" ]; then
        REPO=$(cd "$FILE_DIR" && git remote get-url origin 2>/dev/null | sed -E 's|.*github\.com[:/]||;s|\.git$||' || true)
    fi
fi

if [ -z "$REPO" ]; then
    echo "Error: Could not detect GitHub repo. Pass --repo owner/name"
    exit 2
fi

# --- Build title based on type ---
FILENAME=$(basename "$FILE_PATH")
case "$ESCALATION_TYPE" in
    build-failure)      TITLE="🔴 QA: Build failure in $FILENAME — needs human fix" ;;
    test-failure)       TITLE="🔴 QA: Test failure in $FILENAME — needs human fix" ;;
    security-review)    TITLE="🟡 QA: Security review needed for $FILENAME" ;;
    architecture-review) TITLE="🟡 QA: Architecture review needed for $FILENAME" ;;
    *)                  TITLE="🔴 QA: Escalation for $FILENAME" ;;
esac

# --- Add type-specific labels ---
case "$ESCALATION_TYPE" in
    security-review)    LABELS="$LABELS,security" ;;
    architecture-review) LABELS="$LABELS,architecture" ;;
esac

# --- Build issue body ---
BODY=$(cat <<EOF
## Automated QA Escalation

| Field | Value |
|-------|-------|
| **Type** | \`$ESCALATION_TYPE\` |
| **File** | \`$FILE_PATH\` |
| **Timestamp** | $(date -u +"%Y-%m-%dT%H:%M:%SZ") |

### Error Output
\`\`\`
$ERROR_CONTEXT
\`\`\`

### Codex Analysis
$CODEX_DIAGNOSIS

### What Happened
1. Claude edited \`$FILE_PATH\`
2. The QA hook detected a failure
3. Claude attempted to self-fix but could not resolve it
4. Codex was invoked for deeper analysis (result above)
5. The issue remains unresolved — **senior developer review needed**

### Suggested Actions
- [ ] Review the error and Codex analysis above
- [ ] Identify the root cause
- [ ] Fix and verify locally
- [ ] Close this issue with a link to the fixing commit

---
*Created by [claude-qa-hooks](https://github.com/$REPO) — Layer 4 human escalation*
EOF
)

# --- Create or print ---
if [ "$DRY_RUN" = "true" ]; then
    echo "=== DRY RUN ==="
    echo "Repo: $REPO"
    echo "Title: $TITLE"
    echo "Labels: $LABELS"
    echo "Assignee: ${ASSIGNEE:-<none>}"
    echo ""
    echo "$BODY"
    exit 0
fi

ASSIGN_FLAG=""
if [ -n "$ASSIGNEE" ]; then
    ASSIGN_FLAG="--assignee $ASSIGNEE"
fi

ISSUE_URL=$(gh issue create \
    --repo "$REPO" \
    --title "$TITLE" \
    --label "$LABELS" \
    $ASSIGN_FLAG \
    --body "$BODY" 2>&1)

if [ $? -eq 0 ]; then
    echo "✅ Escalation created: $ISSUE_URL"

    # Log the escalation
    QA_LOG="${CLAUDE_QA_LOG:-$HOME/.claude/qa-log.jsonl}"
    jq -n --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" --arg file "$FILE_PATH" \
          --arg type "$ESCALATION_TYPE" --arg issue "$ISSUE_URL" \
      '{timestamp:$ts,hook:"escalate-to-human",file:$file,type:$type,issue:$issue}' \
      >> "$QA_LOG" 2>/dev/null || true

    # --- Send immediate notification via all channels ---
    SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
    if [ -x "$SCRIPTS_DIR/notify-human.sh" ]; then
        URGENCY="normal"
        case "$ESCALATION_TYPE" in
            security-review) URGENCY="high" ;;
            build-failure|test-failure) URGENCY="normal" ;;
        esac

        "$SCRIPTS_DIR/notify-human.sh" \
            --subject "QA Escalation: $TITLE" \
            --body "Claude Code's QA system needs human help.

Type: $ESCALATION_TYPE
File: $FILE_PATH

Error:
$ERROR_CONTEXT

Codex Analysis:
$CODEX_DIAGNOSIS

Action needed: Review the GitHub Issue and resolve or comment to acknowledge." \
            --issue-url "$ISSUE_URL" \
            --urgency "$URGENCY" || true
    fi
else
    echo "❌ Failed to create issue: $ISSUE_URL"
    exit 1
fi
