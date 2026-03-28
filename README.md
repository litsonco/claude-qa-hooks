# Claude Code QA Hooks

Automated build verification, test running, and E2E coverage auditing for Claude Code sessions. Works across all project types.

## Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/litsonco/claude-qa-hooks/main/install.sh | bash
```

Then restart Claude Code.

## What You Get

### 1. Build Verification (`verify-build.sh`)

Runs automatically after every `Edit` or `Write` on source files:

| File Type | Check | Speed |
|-----------|-------|-------|
| `.swift` | `xcodebuild` (compile, no signing) | ~30-60s |
| `.ts`/`.tsx` | `npx tsc --noEmit` | ~5-15s |
| `.py` | `python3 -m py_compile` | <1s |

### 2. Test Runner (`run-tests.sh`)

Runs automatically after editing TypeScript/JavaScript files:

- **Playwright E2E** — runs when route/handler/middleware files change
- **Jest** — runs related tests for the changed file
- **Vitest** — runs full suite

Only triggers on backend source changes (not every UI edit).

### 3. Coverage Audit (`audit-e2e-coverage.sh`)

On-demand script that checks which API routes have E2E test specs:

```bash
~/.claude/scripts/audit-e2e-coverage.sh /path/to/project
```

Supports:
- **Express** (scans `src/routes/*.ts`)
- **FastAPI** (scans `app/routers/*.py`)
- **Next.js** (scans `app/**/page.tsx`)

## How It Works

The hooks are configured in `~/.claude/settings.json` as `PostToolUse` hooks on `Edit|Write`. Claude Code passes the edited file path as JSON on stdin, and the scripts detect the project type and run the appropriate check.

Results are returned as JSON with `additionalContext` that gets injected back into Claude's context, so it sees build failures immediately.

## Codex Escalation

When a build or test fails and Claude can't fix it in 2 attempts, it spawns a Codex agent in the background with the error context. Codex analyzes the root cause and returns a fix direction. Claude then implements the fix, re-runs the build/tests, and commits.

## Requirements

- Claude Code (any version with hook support)
- `jq` (for install script — `brew install jq` on macOS)
- Project-specific: Xcode CLI tools (Swift), Node.js (TypeScript), Python 3 (Python)
