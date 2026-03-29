#!/bin/bash
# security-test-audit.sh — Scan E2E specs for missing security test categories
#
# Checks each *.spec.ts and its corresponding *.security.spec.ts for coverage
# across the seven security test categories:
#   1. IDOR tests
#   2. Injection tests (SQL, NoSQL, XSS)
#   3. Race condition tests
#   4. Rate limiting tests
#   5. File upload abuse tests
#   6. Enumeration tests
#   7. Boundary input tests
#
# Also checks for the presence of a threat-model.json file and validates
# that project-specific risks are covered.
#
# Usage:
#   security-test-audit.sh [project-dir] [--json]

set -euo pipefail

PROJECT_DIR="${1:-$(pwd)}"
JSON_MODE=false
if [ "${2:-}" = "--json" ] || [ "${1:-}" = "--json" ]; then
    JSON_MODE=true
    if [ "${1:-}" = "--json" ]; then
        PROJECT_DIR="$(pwd)"
    fi
fi

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat <<'HELP'
Usage: security-test-audit.sh [project-dir] [--json]

Scans E2E specs for security test coverage across 7 categories:
  - IDOR (Insecure Direct Object Reference)
  - Injection (SQL, NoSQL, XSS)
  - Race conditions (concurrent requests)
  - Rate limiting
  - File upload abuse
  - Enumeration (info leaks in errors)
  - Boundary inputs (extreme values)

Also checks for project-specific threat model (threat-model.json).
HELP
    exit 0
fi

E2E_DIR="$PROJECT_DIR/e2e"
if [ ! -d "$E2E_DIR" ]; then
    echo "No e2e/ directory found in $PROJECT_DIR"
    exit 1
fi

echo "🔒 Security Test Audit: $(basename "$PROJECT_DIR")"
echo "================================================"

TOTAL_GAPS=0

# Categories and their detection patterns (bash 3 compatible — no associative arrays)
CAT_NAMES="IDOR|Injection|Race Conditions|Rate Limiting|File Upload|Enumeration|Boundary Inputs"
CAT_IDOR="testIDOR|IDOR|another user|attacker.*access|attacker.*cannot"
CAT_INJECTION="testInjection|injection|INJECTION_PAYLOADS|SQL injection|XSS|NoSQL|sanitiz"
CAT_RACE="testConcurrent|testToggleRace|[Cc]oncurrent|[Rr]ace condition|Promise\.all"
CAT_RATE="testRateLimit|rate.limit|429|Too Many Requests|brute.force"
CAT_FILE="testOversizedUpload|testDisguisedFileType|testPathTraversal|oversized|disguised.*file|path.traversal.*upload"
CAT_ENUM="testEnumeration|enumerat|leak.*exist|same.*status.*code|same.*error|same.*response"
CAT_BOUNDARY="testBoundaryInputs|BOUNDARY_INPUTS|extreme.length|unicode|special.char|boundary|10.000|100.000"

# Check each route's functional spec for a corresponding security spec
echo ""
echo "📋 Security Spec Coverage:"
echo ""

for spec in "$E2E_DIR"/*.spec.ts; do
    [ -f "$spec" ] || continue
    basename_spec=$(basename "$spec")

    # Skip security specs themselves and helpers
    case "$basename_spec" in
        *.security.spec.ts|helpers.ts|security-helpers.ts) continue ;;
    esac

    route_name="${basename_spec%.spec.ts}"
    security_spec="$E2E_DIR/${route_name}.security.spec.ts"

    if [ -f "$security_spec" ]; then
        echo "  ✅ $route_name → ${route_name}.security.spec.ts"
    else
        echo "  ❌ $route_name → NO SECURITY SPEC"
        TOTAL_GAPS=$((TOTAL_GAPS + 1))
    fi
done

# Check category coverage across all security specs
echo ""
echo "📊 Category Coverage (across all security specs):"
echo ""

CATEGORY_GAPS=0

check_category() {
    local name="$1" pattern="$2"
    local matches
    matches=$(grep -rlE "$pattern" "$E2E_DIR"/*.security.spec.ts 2>/dev/null | wc -l | tr -d ' ')
    if [ "$matches" -gt 0 ]; then
        echo "  ✅ $name — covered in $matches spec(s)"
    else
        echo "  ❌ $name — NOT COVERED in any security spec"
        CATEGORY_GAPS=$((CATEGORY_GAPS + 1))
    fi
}

check_category "IDOR" "$CAT_IDOR"
check_category "Injection" "$CAT_INJECTION"
check_category "Race Conditions" "$CAT_RACE"
check_category "Rate Limiting" "$CAT_RATE"
check_category "File Upload" "$CAT_FILE"
check_category "Enumeration" "$CAT_ENUM"
check_category "Boundary Inputs" "$CAT_BOUNDARY"

# Check for threat model
echo ""
echo "📐 Threat Model:"
echo ""

THREAT_MODEL="$PROJECT_DIR/threat-model.json"
if [ -f "$THREAT_MODEL" ]; then
    echo "  ✅ threat-model.json found"

    # Check if project-specific risks are covered in tests
    RISK_COUNT=$(jq '.risks | length' "$THREAT_MODEL" 2>/dev/null || echo "0")
    COVERED=0
    UNCOVERED=0

    if [ "$RISK_COUNT" -gt 0 ]; then
        echo "  📋 Project-specific risks ($RISK_COUNT defined):"
        jq -r '.risks[] | "    \(.id): \(.name) [\(.severity)]"' "$THREAT_MODEL" 2>/dev/null

        echo ""
        echo "  Coverage of threat model risks in security specs:"
        jq -r '.risks[] | .test_pattern // .id' "$THREAT_MODEL" 2>/dev/null | while read -r pattern; do
            if grep -rlE "$pattern" "$E2E_DIR"/*.security.spec.ts &>/dev/null; then
                echo "    ✅ $pattern"
                COVERED=$((COVERED + 1))
            else
                echo "    ❌ $pattern — NOT TESTED"
                UNCOVERED=$((UNCOVERED + 1))
            fi
        done
    fi
else
    echo "  ⚠️  No threat-model.json found"
    echo "  Create one to define project-specific security risks."
    echo "  Run: claude 'generate a threat model for this project'"
fi

# Summary
echo ""
echo "================================================"
echo "Security spec gaps: $TOTAL_GAPS"
echo "Category gaps: $CATEGORY_GAPS"
echo ""
if [ $TOTAL_GAPS -eq 0 ] && [ $CATEGORY_GAPS -eq 0 ]; then
    echo "✅ All routes have security specs, all categories covered"
else
    echo "⚠️  $(( TOTAL_GAPS + CATEGORY_GAPS )) total gap(s) found"
fi

exit $((TOTAL_GAPS + CATEGORY_GAPS))
