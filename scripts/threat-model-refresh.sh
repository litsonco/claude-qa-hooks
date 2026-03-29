#!/bin/bash
# threat-model-refresh.sh — Detect when threat-model.json is stale
#
# Compares the current codebase against the threat model and flags:
#   1. Routes/routers that exist in code but aren't referenced in the threat model
#   2. Endpoints in the threat model that no longer exist in code
#   3. New file upload endpoints without upload-abuse risks defined
#   4. New auth/role patterns without privilege-escalation risks
#   5. New external integrations (Stripe, SendGrid, AI) without corresponding risks
#
# Usage:
#   threat-model-refresh.sh [project-dir] [--json] [--fix]
#
# Options:
#   --json    Output as JSON
#   --fix     Attempt to add missing entries (outputs suggested additions)
#   --help    Show this help

set -euo pipefail

PROJECT_DIR="${1:-$(pwd)}"
JSON_MODE=false
FIX_MODE=false

for arg in "$@"; do
    case "$arg" in
        --json) JSON_MODE=true ;;
        --fix)  FIX_MODE=true ;;
        --help|-h)
            head -14 "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
    esac
done

THREAT_MODEL="$PROJECT_DIR/threat-model.json"

if [ ! -f "$THREAT_MODEL" ]; then
    echo "No threat-model.json found in $PROJECT_DIR"
    echo "Create one with: claude 'generate a threat model for this project'"
    exit 1
fi

echo "🔍 Threat Model Freshness Check: $(basename "$PROJECT_DIR")"
echo "================================================"

STALE_COUNT=0
NEW_ROUTES=""
DEAD_ENDPOINTS=""
NEW_UPLOADS=""
NEW_AUTH=""
NEW_INTEGRATIONS=""

# --- 1. Find routes/routers in code ---
CODE_ROUTES=""

# Express routes (src/routes/*.ts)
if [ -d "$PROJECT_DIR/src/routes" ]; then
    for f in "$PROJECT_DIR/src/routes"/*.ts "$PROJECT_DIR/src/routes"/*.js; do
        [ -f "$f" ] || continue
        route=$(basename "$f" | sed -E 's/\.(ts|js)$//')
        CODE_ROUTES="$CODE_ROUTES $route"
    done
fi

# FastAPI routers (app/routers/*.py)
if [ -d "$PROJECT_DIR/app/routers" ]; then
    for f in "$PROJECT_DIR/app/routers"/*.py; do
        [ -f "$f" ] || continue
        router=$(basename "$f" .py)
        [ "$router" = "__init__" ] && continue
        [ "$router" = "__pycache__" ] && continue
        CODE_ROUTES="$CODE_ROUTES $router"
    done
fi

# Get endpoints referenced in threat model
MODEL_ENDPOINTS=$(jq -r '.risks[].endpoints[]? // empty' "$THREAT_MODEL" 2>/dev/null | sort -u)

# --- 2. Check for routes not covered by any risk ---
echo ""
echo "📡 Route Coverage:"
echo ""

for route in $CODE_ROUTES; do
    # Check if this route name appears in any threat model endpoint
    if echo "$MODEL_ENDPOINTS" | grep -qi "$route"; then
        echo "  ✅ $route — referenced in threat model"
    else
        echo "  ⚠️  $route — NOT in any threat model risk endpoint list"
        STALE_COUNT=$((STALE_COUNT + 1))
        NEW_ROUTES="$NEW_ROUTES $route"
    fi
done

# --- 3. Check for dead endpoints in threat model ---
echo ""
echo "📐 Threat Model Endpoint Validity:"
echo ""

for endpoint in $MODEL_ENDPOINTS; do
    # Extract the route name from the endpoint pattern
    route_part=$(echo "$endpoint" | sed -E 's|^/||;s|/.*||;s/\*//g;s/\{[^}]*\}//g')

    found=false
    for route in $CODE_ROUTES; do
        if echo "$route" | grep -qi "$route_part" || echo "$route_part" | grep -qi "$route"; then
            found=true
            break
        fi
    done

    if [ "$found" = "true" ]; then
        echo "  ✅ $endpoint — route exists"
    else
        echo "  ❌ $endpoint — route may no longer exist"
        STALE_COUNT=$((STALE_COUNT + 1))
        DEAD_ENDPOINTS="$DEAD_ENDPOINTS $endpoint"
    fi
done

# --- 4. Detect new file upload endpoints ---
echo ""
echo "📎 File Upload Detection:"
echo ""

UPLOAD_PATTERNS="UploadFile|multer|upload|File\(\.\.\.\)|multipart"
UPLOAD_FILES=$(grep -rlE "$UPLOAD_PATTERNS" "$PROJECT_DIR/src" "$PROJECT_DIR/app" 2>/dev/null | grep -v node_modules | grep -v __pycache__ || true)

if [ -n "$UPLOAD_FILES" ]; then
    MODEL_HAS_UPLOAD=$(jq -r '.risks[] | select(.name | test("upload|file|document"; "i")) | .id' "$THREAT_MODEL" 2>/dev/null)

    if [ -z "$MODEL_HAS_UPLOAD" ]; then
        echo "  ⚠️  Code has file upload endpoints but threat model has NO upload-related risks"
        STALE_COUNT=$((STALE_COUNT + 1))
        NEW_UPLOADS="file_upload"
    else
        echo "  ✅ File uploads detected — threat model has upload risks: $MODEL_HAS_UPLOAD"
    fi
else
    echo "  — No file upload endpoints detected"
fi

# --- 5. Detect new auth/role patterns ---
echo ""
echo "🔐 Auth Pattern Detection:"
echo ""

ROLE_PATTERNS="admin|moderator|superuser|role.*check|is_admin|is_moderator|get_current_admin|get_current_moderator|UserRole|require.*role"
ROLE_FILES=$(grep -rlE "$ROLE_PATTERNS" "$PROJECT_DIR/src" "$PROJECT_DIR/app" 2>/dev/null | grep -v node_modules | grep -v __pycache__ || true)
ROLE_COUNT=$(echo "$ROLE_FILES" | grep -c . 2>/dev/null || echo "0")

MODEL_HAS_ROLE_RISK=$(jq -r '.risks[] | select(.name | test("role|privilege|escalat|admin"; "i")) | .id' "$THREAT_MODEL" 2>/dev/null)

if [ "$ROLE_COUNT" -gt 0 ] && [ -z "$MODEL_HAS_ROLE_RISK" ]; then
    echo "  ⚠️  Code has role-based auth ($ROLE_COUNT files) but threat model has NO privilege escalation risk"
    STALE_COUNT=$((STALE_COUNT + 1))
    NEW_AUTH="role_escalation"
else
    echo "  ✅ Role-based auth detected — threat model covers it: ${MODEL_HAS_ROLE_RISK:-n/a}"
fi

# --- 6. Detect external integrations ---
echo ""
echo "🔌 External Integration Detection:"
echo ""

check_integration() {
    local name="$1" pattern="$2" risk_pattern="$3"
    local found
    found=$(grep -rlE "$pattern" "$PROJECT_DIR/src" "$PROJECT_DIR/app" "$PROJECT_DIR/package.json" "$PROJECT_DIR/requirements.txt" 2>/dev/null | grep -v node_modules | head -1 || true)

    if [ -n "$found" ]; then
        model_risk=$(jq -r ".risks[] | select(.name | test(\"$risk_pattern\"; \"i\")) | .id" "$THREAT_MODEL" 2>/dev/null)
        if [ -z "$model_risk" ]; then
            echo "  ⚠️  $name integration found but NO corresponding threat model risk"
            STALE_COUNT=$((STALE_COUNT + 1))
            NEW_INTEGRATIONS="$NEW_INTEGRATIONS $name"
        else
            echo "  ✅ $name — covered by risk $model_risk"
        fi
    fi
}

check_integration "Stripe" "stripe|STRIPE" "payment|stripe|billing"
check_integration "SendGrid" "sendgrid|SENDGRID" "email|sendgrid|spam"
check_integration "OpenAI/AI" "openai|anthropic|OPENAI|generate.*story|ai.*prompt" "AI|prompt|content.*safety|generat"
check_integration "AWS S3" "aws-sdk|s3.*bucket|S3Client" "storage|s3|bucket"
check_integration "MongoDB" "mongodb|mongoose|beanie|motor" "database|mongo|injection"

# --- Summary ---
echo ""
echo "================================================"

if [ $STALE_COUNT -eq 0 ]; then
    echo "✅ Threat model is current — no drift detected"
else
    echo "⚠️  $STALE_COUNT issue(s) found — threat model may be stale"
    echo ""

    if [ "$FIX_MODE" = "true" ]; then
        echo "📝 Suggested updates for threat-model.json:"
        echo ""

        if [ -n "$NEW_ROUTES" ]; then
            echo "  New routes to evaluate for risks:$NEW_ROUTES"
        fi
        if [ -n "$DEAD_ENDPOINTS" ]; then
            echo "  Endpoints to remove (no longer in code):$DEAD_ENDPOINTS"
        fi
        if [ -n "$NEW_UPLOADS" ]; then
            echo "  Add file upload abuse risk (code has upload endpoints)"
        fi
        if [ -n "$NEW_AUTH" ]; then
            echo "  Add privilege escalation risk (code has role-based auth)"
        fi
        if [ -n "$NEW_INTEGRATIONS" ]; then
            echo "  Add risks for new integrations:$NEW_INTEGRATIONS"
        fi

        echo ""
        echo "  Run: claude 'update threat-model.json based on current codebase'"
    fi
fi

exit $STALE_COUNT
