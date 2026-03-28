#!/bin/bash
# audit-e2e-coverage.sh — Check that all API routes and core flows have E2E tests
#
# Usage: ~/.claude/scripts/audit-e2e-coverage.sh [project-dir]
# Output: List of untested routes/pages
#
# Works for:
#   - Express/Node (scans src/routes/*.ts for route handlers)
#   - FastAPI/Python (scans app/routers/*.py for route decorators)
#   - Next.js (scans app/*/page.tsx or pages/*.tsx for pages)

set -uo pipefail

PROJECT_DIR="${1:-$(pwd)}"
cd "$PROJECT_DIR"

echo "🔍 E2E Coverage Audit: $(basename "$PROJECT_DIR")"
echo "================================================"

GAPS=0

# --- Detect project type and find routes ---

# Express/TypeScript routes
if [ -d "src/routes" ]; then
    echo ""
    echo "📡 Express API Routes:"
    echo ""

    for route_file in src/routes/*.ts src/routes/*.js; do
        [ -f "$route_file" ] || continue
        route_name=$(basename "$route_file" | sed -E 's/\.(ts|js)$//')

        # Check if there's a matching e2e spec (case-insensitive, kebab-case variants)
        SPEC_EXISTS=false
        route_lower=$(echo "$route_name" | tr '[:upper:]' '[:lower:]')
        route_kebab=$(echo "$route_name" | sed 's/\([A-Z]\)/-\L\1/g' | sed 's/^-//')
        for spec in e2e/${route_name}.spec.ts e2e/${route_name}.spec.js e2e/${route_lower}.spec.ts e2e/${route_kebab}.spec.ts; do
            [ -f "$spec" ] && SPEC_EXISTS=true && break
        done

        if [ "$SPEC_EXISTS" = "true" ]; then
            echo "  ✅ $route_name → $(ls e2e/${route_name}*.spec.* 2>/dev/null | head -1)"
        else
            echo "  ❌ $route_name → NO E2E SPEC"
            GAPS=$((GAPS + 1))
        fi
    done
fi

# FastAPI/Python routers
if [ -d "app/routers" ]; then
    echo ""
    echo "📡 FastAPI Routers:"
    echo ""

    for router_file in app/routers/*.py; do
        [ -f "$router_file" ] || continue
        router_name=$(basename "$router_file" .py)
        [ "$router_name" = "__init__" ] && continue
        [ "$router_name" = "__pycache__" ] && continue

        SPEC_EXISTS=false
        router_kebab=$(echo "$router_name" | tr '_' '-')
        for spec in e2e/${router_name}.spec.ts e2e/${router_name}.spec.js e2e/${router_kebab}.spec.ts; do
            [ -f "$spec" ] && SPEC_EXISTS=true && break
        done

        if [ "$SPEC_EXISTS" = "true" ]; then
            echo "  ✅ $router_name → $(ls e2e/${router_name}*.spec.* 2>/dev/null | head -1)"
        else
            echo "  ❌ $router_name → NO E2E SPEC"
            GAPS=$((GAPS + 1))
        fi
    done
fi

# Next.js pages (App Router)
if [ -d "app" ] && [ -f "next.config.ts" -o -f "next.config.js" -o -f "next.config.mjs" ]; then
    echo ""
    echo "🌐 Next.js Pages:"
    echo ""

    find app -name "page.tsx" -o -name "page.ts" -o -name "page.jsx" -o -name "page.js" | sort | while read -r page_file; do
        # Convert app/foo/bar/page.tsx → /foo/bar
        route=$(echo "$page_file" | sed 's|^app||' | sed 's|/page\.\(tsx\|ts\|jsx\|js\)$||' | sed 's|^$|/|')
        route_name=$(echo "$route" | tr '/' '-' | sed 's/^-//' | sed 's/^$/homepage/')

        SPEC_EXISTS=false
        for spec in e2e/web/${route_name}*.spec.ts e2e/${route_name}*.spec.ts; do
            [ -f "$spec" ] && SPEC_EXISTS=true && break
        done

        if [ "$SPEC_EXISTS" = "true" ]; then
            echo "  ✅ $route → has spec"
        else
            echo "  ⚠️  $route → no E2E spec (may be OK for non-critical pages)"
        fi
    done
fi

# Next.js pages in monorepo apps
for app_dir in apps/*/; do
    [ -d "$app_dir" ] || continue
    if [ -d "${app_dir}app" ] || [ -d "${app_dir}src/app" ]; then
        app_name=$(basename "$app_dir")
        page_dir="${app_dir}app"
        [ -d "${app_dir}src/app" ] && page_dir="${app_dir}src/app"

        echo ""
        echo "🌐 Next.js Pages ($app_name):"
        echo ""

        find "$page_dir" -name "page.tsx" -o -name "page.ts" 2>/dev/null | sort | while read -r page_file; do
            route=$(echo "$page_file" | sed "s|^${page_dir}||" | sed 's|/page\.\(tsx\|ts\)$||' | sed 's|^$|/|')
            echo "  📄 $route"
        done
    fi
done

# --- Summary ---
echo ""
echo "================================================"
if [ $GAPS -gt 0 ]; then
    echo "⚠️  $GAPS route(s) missing E2E coverage"
    echo ""
    echo "To fix, create specs in e2e/ for each ❌ route."
    echo "Template: ~/.claude/scripts/audit-e2e-coverage.sh --help"
else
    echo "✅ All detected routes have E2E specs"
fi
echo ""

exit $GAPS
