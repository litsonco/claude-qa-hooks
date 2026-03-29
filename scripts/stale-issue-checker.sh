#!/bin/bash
# stale-issue-checker.sh — Find stale QA escalation issues and send reminders
#
# Checks for open GitHub Issues with the 'needs-human' label that haven't
# received a response within the configured time window. Sends reminders
# via email and GitHub comments with escalating urgency.
#
# Usage:
#   stale-issue-checker.sh [options]
#
# Options:
#   --repo OWNER/REPO     GitHub repo to check (default: auto-detect or CLAUDE_QA_REPOS)
#   --remind-after HOURS   Hours before first reminder (default: 12)
#   --escalate-after HOURS Hours before team-wide escalation (default: 24)
#   --dry-run              Print what would happen without acting
#
# Environment:
#   CLAUDE_QA_REPOS        Comma-separated repos to check (e.g., "litsonco/clemency-backend,litsonco/storytime-magic")
#   CLAUDE_QA_EMAIL        Primary notification email
#   CLAUDE_QA_EMAIL_CC     CC for escalation emails
#   CLAUDE_QA_REVIEWER     GitHub handle for assignment
#
# Designed to run as a cron job every 2 hours:
#   0 */2 * * * ~/.claude/scripts/stale-issue-checker.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPOS="${CLAUDE_QA_REPOS:-}"
REMIND_AFTER=12
ESCALATE_AFTER=24
DRY_RUN=false
QA_LOG="${CLAUDE_QA_LOG:-$HOME/.claude/qa-log.jsonl}"

while [ $# -gt 0 ]; do
    case "$1" in
        --repo)            REPOS="$2"; shift 2 ;;
        --remind-after)    REMIND_AFTER="$2"; shift 2 ;;
        --escalate-after)  ESCALATE_AFTER="$2"; shift 2 ;;
        --dry-run)         DRY_RUN=true; shift ;;
        --help|-h)
            head -20 "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 2 ;;
    esac
done

if [ -z "$REPOS" ]; then
    echo "Error: No repos specified. Set CLAUDE_QA_REPOS or use --repo."
    echo "Example: export CLAUDE_QA_REPOS='litsonco/clemency-backend,litsonco/storytime-magic'"
    exit 2
fi

if ! command -v gh &>/dev/null; then
    echo "Error: gh CLI is required"
    exit 2
fi

# Get current time in epoch seconds
NOW=$(date +%s)
REMIND_THRESHOLD=$((NOW - REMIND_AFTER * 3600))
ESCALATE_THRESHOLD=$((NOW - ESCALATE_AFTER * 3600))

REMINDED=0
ESCALATED=0

IFS=',' read -ra REPO_LIST <<< "$REPOS"

for repo in "${REPO_LIST[@]}"; do
    repo=$(echo "$repo" | xargs)  # trim whitespace

    # Find open issues with needs-human label
    ISSUES=$(gh issue list --repo "$repo" --label "needs-human" --state open \
        --json number,title,createdAt,url,comments \
        --jq '.[] | "\(.number)\t\(.title)\t\(.createdAt)\t\(.url)\t\(.comments | length)"' \
        2>/dev/null) || continue

    if [ -z "$ISSUES" ]; then
        continue
    fi

    while IFS=$'\t' read -r number title created_at url comment_count; do
        # Parse ISO date to epoch
        if date -j -f "%Y-%m-%dT%H:%M:%SZ" "$created_at" +%s &>/dev/null 2>&1; then
            # macOS date
            CREATED_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$created_at" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%T" "${created_at%%Z*}" +%s 2>/dev/null || echo "0")
        else
            # GNU date
            CREATED_EPOCH=$(date -d "$created_at" +%s 2>/dev/null || echo "0")
        fi

        if [ "$CREATED_EPOCH" = "0" ]; then
            continue
        fi

        AGE_HOURS=$(( (NOW - CREATED_EPOCH) / 3600 ))

        # Check if we already reminded (look for bot comments)
        ALREADY_REMINDED=false
        if [ "$comment_count" -gt 0 ]; then
            # Check if any comment contains our reminder marker
            REMINDER_COMMENTS=$(gh issue view "$number" --repo "$repo" \
                --json comments --jq '.comments[].body' 2>/dev/null | \
                grep -c "automated reminder from claude-qa-hooks" || true)
            if [ "$REMINDER_COMMENTS" -gt 0 ]; then
                ALREADY_REMINDED=true
            fi
        fi

        # --- Escalation tier (>24h, no response) ---
        if [ "$CREATED_EPOCH" -lt "$ESCALATE_THRESHOLD" ]; then
            # Check if we already escalated (look for escalation marker)
            ALREADY_ESCALATED=false
            if [ "$comment_count" -gt 0 ]; then
                ESC_COMMENTS=$(gh issue view "$number" --repo "$repo" \
                    --json comments --jq '.comments[].body' 2>/dev/null | \
                    grep -c "ESCALATION: 24-hour" || true)
                if [ "$ESC_COMMENTS" -gt 0 ]; then
                    ALREADY_ESCALATED=true
                fi
            fi

            if [ "$ALREADY_ESCALATED" = "false" ]; then
                echo "🔴 ESCALATING: $repo#$number — $title (${AGE_HOURS}h old)"

                DRY_FLAG=""
                if [ "$DRY_RUN" = "true" ]; then
                    DRY_FLAG="--dry-run"
                    echo "  [DRY RUN] Would escalate"
                else
                    # Add escalation comment
                    gh issue comment "$number" --repo "$repo" \
                        --body "**🔴 ESCALATION: 24-hour deadline passed**

This QA issue has been open for **${AGE_HOURS} hours** without a response.

Escalating to the full team. Please prioritize this — unresolved QA failures can compound.

_This is an automated escalation from claude-qa-hooks._" 2>/dev/null || true

                    # Add 'urgent' label
                    gh issue edit "$number" --repo "$repo" --add-label "urgent" 2>/dev/null || true
                fi

                # Send escalation email to team
                if [ -x "$SCRIPTS_DIR/notify-human.sh" ]; then
                    "$SCRIPTS_DIR/notify-human.sh" $DRY_FLAG \
                        --subject "🔴 URGENT: QA issue open ${AGE_HOURS}h — $title" \
                        --body "This QA escalation has been open for ${AGE_HOURS} hours with no response.

Issue: $repo#$number
Title: $title
Link: $url

Please review and resolve, or comment on the issue to acknowledge." \
                        --issue-url "$url" \
                        --urgency high
                fi

                ESCALATED=$((ESCALATED + 1))
            fi

        # --- Reminder tier (>12h, no response) ---
        elif [ "$CREATED_EPOCH" -lt "$REMIND_THRESHOLD" ] && [ "$ALREADY_REMINDED" = "false" ]; then
            echo "🟡 REMINDING: $repo#$number — $title (${AGE_HOURS}h old)"

            DRY_FLAG=""
            if [ "$DRY_RUN" = "true" ]; then
                DRY_FLAG="--dry-run"
                echo "  [DRY RUN] Would send reminder"
            else
                # Add reminder comment on the issue
                gh issue comment "$number" --repo "$repo" \
                    --body "**🔔 Reminder: ${AGE_HOURS}h without response**

This QA issue needs human attention. If it's not addressed within the next 12 hours, it will be escalated to the full team.

To dismiss this reminder, comment on the issue or close it.

_This is an automated reminder from claude-qa-hooks._" 2>/dev/null || true
            fi

            # Send reminder email
            if [ -x "$SCRIPTS_DIR/notify-human.sh" ]; then
                "$SCRIPTS_DIR/notify-human.sh" $DRY_FLAG \
                    --subject "🟡 Reminder: QA issue needs review — $title" \
                    --body "A QA escalation has been waiting ${AGE_HOURS} hours for human review.

Issue: $repo#$number
Title: $title
Link: $url

If not resolved within 24 hours, this will escalate to the full team." \
                    --issue-url "$url" \
                    --urgency normal \
                    --repo "$repo" \
                    --issue-number "$number"
            fi

            REMINDED=$((REMINDED + 1))
        fi

    done <<< "$ISSUES"
done

# Summary
if [ $REMINDED -gt 0 ] || [ $ESCALATED -gt 0 ]; then
    echo ""
    echo "Summary: $REMINDED reminder(s), $ESCALATED escalation(s)"
else
    echo "✅ No stale QA issues found"
fi

# Log the check
if [ "$DRY_RUN" = "false" ]; then
    jq -n --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
          --argjson reminded "$REMINDED" --argjson escalated "$ESCALATED" \
      '{timestamp:$ts,hook:"stale-issue-checker",reminded:$reminded,escalated:$escalated}' \
      >> "$QA_LOG" 2>/dev/null || true
fi
