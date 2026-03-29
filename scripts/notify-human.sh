#!/bin/bash
# notify-human.sh — Multi-channel human notification
#
# Sends notifications via all available channels:
#   1. macOS notification center (immediate, always works locally)
#   2. Email via SendGrid API (if SENDGRID_API_KEY is set)
#   3. Email via system mail (if /usr/bin/mail is available and SENDGRID is not)
#   4. GitHub Issue comment (for follow-up reminders)
#
# Usage:
#   notify-human.sh --subject "Title" --body "Details" [options]
#
# Options:
#   --subject TEXT       Notification subject/title
#   --body TEXT          Notification body (plain text)
#   --email ADDRESS      Email recipient (default: CLAUDE_QA_EMAIL or CLAUDE_QA_REVIEWER@github)
#   --urgency low|normal|high  Affects macOS notification sound
#   --issue-url URL      GitHub Issue URL (included in email)
#   --channel all|email|macos|github  Which channels to use (default: all)
#   --repo OWNER/REPO    GitHub repo for issue comments
#   --issue-number N     Issue number for adding comments
#   --dry-run            Print what would be sent without sending
#
# Environment:
#   CLAUDE_QA_EMAIL          Primary notification email address
#   CLAUDE_QA_EMAIL_CC       CC addresses (comma-separated)
#   SENDGRID_API_KEY         SendGrid API key for email delivery
#   SENDGRID_FROM_EMAIL      From address for SendGrid (default: qa@litson.co)
#   CLAUDE_QA_REVIEWER       GitHub handle (fallback for email: handle@users.noreply.github.com)

set -euo pipefail

SUBJECT=""
BODY=""
EMAIL="${CLAUDE_QA_EMAIL:-}"
EMAIL_CC="${CLAUDE_QA_EMAIL_CC:-}"
URGENCY="normal"
ISSUE_URL=""
CHANNEL="all"
REPO=""
ISSUE_NUMBER=""
DRY_RUN=false
FROM_EMAIL="${SENDGRID_FROM_EMAIL:-qa@litson.co}"
QA_LOG="${CLAUDE_QA_LOG:-$HOME/.claude/qa-log.jsonl}"

while [ $# -gt 0 ]; do
    case "$1" in
        --subject)      SUBJECT="$2"; shift 2 ;;
        --body)         BODY="$2"; shift 2 ;;
        --email)        EMAIL="$2"; shift 2 ;;
        --urgency)      URGENCY="$2"; shift 2 ;;
        --issue-url)    ISSUE_URL="$2"; shift 2 ;;
        --channel)      CHANNEL="$2"; shift 2 ;;
        --repo)         REPO="$2"; shift 2 ;;
        --issue-number) ISSUE_NUMBER="$2"; shift 2 ;;
        --dry-run)      DRY_RUN=true; shift ;;
        --help|-h)
            head -20 "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 2 ;;
    esac
done

if [ -z "$SUBJECT" ] || [ -z "$BODY" ]; then
    echo "Error: --subject and --body are required"
    exit 2
fi

# Build email body with issue link
EMAIL_BODY="$BODY"
if [ -n "$ISSUE_URL" ]; then
    EMAIL_BODY="$EMAIL_BODY

---
GitHub Issue: $ISSUE_URL

View and respond directly on GitHub, or reply to this email."
fi

EMAIL_BODY="$EMAIL_BODY

---
Sent by claude-qa-hooks notification system
To configure: export CLAUDE_QA_EMAIL=your@email.com in ~/.zshrc"

SENT_VIA=""

# =========================================================================
# Channel 1: macOS Notification Center
# =========================================================================
send_macos() {
    if [ "$(uname)" != "Darwin" ]; then return 1; fi

    local sound=""
    case "$URGENCY" in
        high) sound='sound name "Sosumi"' ;;
        normal) sound='sound name "Pop"' ;;
        *) sound="" ;;
    esac

    if [ "$DRY_RUN" = "true" ]; then
        echo "[DRY RUN] macOS notification: $SUBJECT"
        return 0
    fi

    osascript -e "display notification \"$BODY\" with title \"QA Hook Alert\" subtitle \"$SUBJECT\" $sound" 2>/dev/null && \
        SENT_VIA="$SENT_VIA macos" || true
}

# =========================================================================
# Channel 2: Email via SendGrid API
# =========================================================================
send_sendgrid() {
    if [ -z "${SENDGRID_API_KEY:-}" ]; then return 1; fi
    if [ -z "$EMAIL" ]; then return 1; fi

    if [ "$DRY_RUN" = "true" ]; then
        echo "[DRY RUN] SendGrid email to $EMAIL: $SUBJECT"
        return 0
    fi

    # Build recipient list
    local to_json
    to_json=$(echo "$EMAIL" | tr ',' '\n' | sed 's/^ *//' | jq -R '{email:.}' | jq -s '.')

    local cc_json="[]"
    if [ -n "$EMAIL_CC" ]; then
        cc_json=$(echo "$EMAIL_CC" | tr ',' '\n' | sed 's/^ *//' | jq -R '{email:.}' | jq -s '.')
    fi

    local payload
    payload=$(jq -n \
        --argjson to "$to_json" \
        --argjson cc "$cc_json" \
        --arg from "$FROM_EMAIL" \
        --arg subject "$SUBJECT" \
        --arg body "$EMAIL_BODY" \
        '{
            personalizations: [{to: $to, cc: (if ($cc | length) > 0 then $cc else empty end)}],
            from: {email: $from, name: "Claude QA Hooks"},
            subject: $subject,
            content: [{type: "text/plain", value: $body}]
        }')

    local response
    response=$(curl -s -o /dev/null -w "%{http_code}" \
        --request POST \
        --url https://api.sendgrid.com/v3/mail/send \
        --header "Authorization: Bearer $SENDGRID_API_KEY" \
        --header "Content-Type: application/json" \
        --data "$payload" 2>&1)

    if [ "$response" = "202" ] || [ "$response" = "200" ]; then
        SENT_VIA="$SENT_VIA sendgrid"
        return 0
    fi
    return 1
}

# =========================================================================
# Channel 3: Email via system mail
# =========================================================================
send_system_mail() {
    if ! command -v mail &>/dev/null; then return 1; fi
    if [ -z "$EMAIL" ]; then return 1; fi

    if [ "$DRY_RUN" = "true" ]; then
        echo "[DRY RUN] System mail to $EMAIL: $SUBJECT"
        return 0
    fi

    local cc_flag=""
    if [ -n "$EMAIL_CC" ]; then
        cc_flag="-c $EMAIL_CC"
    fi

    echo "$EMAIL_BODY" | mail -s "$SUBJECT" $cc_flag "$EMAIL" 2>/dev/null && \
        SENT_VIA="$SENT_VIA system-mail" || true
}

# =========================================================================
# Channel 4: GitHub Issue comment
# =========================================================================
send_github_comment() {
    if [ -z "$REPO" ] || [ -z "$ISSUE_NUMBER" ]; then return 1; fi
    if ! command -v gh &>/dev/null; then return 1; fi

    if [ "$DRY_RUN" = "true" ]; then
        echo "[DRY RUN] GitHub comment on $REPO#$ISSUE_NUMBER"
        return 0
    fi

    gh issue comment "$ISSUE_NUMBER" --repo "$REPO" \
        --body "**🔔 Reminder:** $SUBJECT

$BODY

_This is an automated reminder from claude-qa-hooks. The issue has been open without a response._" 2>/dev/null && \
        SENT_VIA="$SENT_VIA github-comment" || true
}

# =========================================================================
# Send via configured channels
# =========================================================================
case "$CHANNEL" in
    all)
        send_macos
        send_sendgrid || send_system_mail || true
        # GitHub comment only for reminders, not initial notification
        if [ -n "$ISSUE_NUMBER" ]; then
            send_github_comment
        fi
        ;;
    email)
        send_sendgrid || send_system_mail || echo "Warning: No email method available. Set SENDGRID_API_KEY or configure system mail."
        ;;
    macos)
        send_macos
        ;;
    github)
        send_github_comment
        ;;
    *)
        echo "Unknown channel: $CHANNEL"
        exit 2
        ;;
esac

# Log the notification
if [ "$DRY_RUN" = "false" ]; then
    local_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    jq -n --arg ts "$local_ts" --arg subject "$SUBJECT" --arg channels "$SENT_VIA" \
          --arg email "$EMAIL" --arg issue "$ISSUE_URL" \
      '{timestamp:$ts,hook:"notify-human",subject:$subject,channels:$channels,email:$email,issue:$issue}' \
      >> "$QA_LOG" 2>/dev/null || true

    if [ -n "$SENT_VIA" ]; then
        echo "✅ Notification sent via:$SENT_VIA"
    else
        echo "⚠️  No notification channels were available. Configure CLAUDE_QA_EMAIL and/or SENDGRID_API_KEY."
    fi
fi
