# Claude Code QA Hooks

**Automated build verification, test running, and code review escalation for Claude Code.**

Catches compilation errors the moment they're introduced, runs E2E tests on backend changes, and escalates to Codex when Claude can't self-fix. Works across Swift, TypeScript, Python, and any Xcode/Node/Python project.

## Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/litsonco/claude-qa-hooks/main/install.sh | bash
```

Then restart Claude Code.

---

## Architecture

```
                         You edit code via Claude Code
                                    |
                                    v
                    +-------------------------------+
                    |     PostToolUse Hook Fires     |
                    |   (after every Edit / Write)   |
                    +-------------------------------+
                                    |
                         What file was edited?
                                    |
              +---------------------+---------------------+
              |                     |                     |
         .swift file           .ts/.tsx file          .py file
              |                     |                     |
              v                     v                     v
     +----------------+   +------------------+   +----------------+
     | verify-build   |   | verify-build     |   | verify-build   |
     | xcodebuild     |   | tsc --noEmit     |   | py_compile     |
     | (compile-only) |   | (type-check)     |   | (syntax check) |
     +----------------+   +------------------+   +----------------+
              |                     |                     |
              |              +------+------+              |
              |              |             |              |
              |        Route/handler?   Other TS?         |
              |              |             |              |
              |              v             |              |
              |     +----------------+    |              |
              |     | run-tests      |    |              |
              |     | Playwright E2E |    |              |
              |     | Jest / Vitest  |    |              |
              |     +----------------+    |              |
              |              |             |              |
              +------+-------+------+------+--------------+
                     |              |
                  PASSED          FAILED
                     |              |
                     v              v
              +----------+  +--------------------+
              |   Done   |  | Claude reads error  |
              | Continue |  | Can fix in <2 min?  |
              | working  |  +--------------------+
              +----------+         |          |
                                  YES         NO
                                   |          |
                                   v          v
                            +---------+  +------------------+
                            | Fix it  |  | Spawn Codex      |
                            | Re-run  |  | agent in          |
                            | hook    |  | background        |
                            +---------+  +------------------+
                                                |
                                                v
                                    +------------------------+
                                    | Codex returns diagnosis |
                                    | + fix with file:line    |
                                    +------------------------+
                                                |
                                                v
                                    +------------------------+
                                    | Claude implements fix   |
                                    | Hook re-verifies        |
                                    | Commit when green       |
                                    +------------------------+
```

---

## The Three Layers

### Layer 1: Build Verification (`verify-build.sh`)

Fires after every `Edit` or `Write` on source files. Detects the project type from the file extension and runs the fastest possible compilation check.

| File Type | What Runs | What It Catches | Speed |
|-----------|-----------|-----------------|-------|
| `.swift` | `xcodebuild` (generic iOS, no signing) | Type errors, missing imports, protocol conformance | ~30-60s |
| `.ts` / `.tsx` | `npx tsc --noEmit` | Type errors, interface mismatches, import issues | ~5-15s |
| `.py` | `python3 -m py_compile` | Syntax errors, indentation issues | <1s |
| `.js` / `.jsx` | ESLint (if available) | Lint errors, unused vars | ~2-5s |

**Key design decision:** Type-checking only, not full builds. Fast enough to run on every edit without disrupting flow.

### Layer 2: Test Runner (`run-tests.sh`)

Fires after editing TypeScript/JavaScript files. Detects the test framework and runs the appropriate suite, but only when it matters.

| What Changed | What Runs | Why |
|-------------|-----------|-----|
| `src/routes/*` | Playwright E2E (full suite) | Route changes can break API contracts |
| `src/handlers/*` | Playwright E2E (full suite) | Handler logic affects API behavior |
| `src/middleware/*` | Playwright E2E (full suite) | Middleware changes affect all routes |
| `src/utils/*` | Jest (related tests only) | Utility changes need unit verification |
| `e2e/*.spec.ts` | Playwright (that spec only) | Verify the test itself passes |
| `*.tsx` (frontend) | Nothing (type-check only) | E2E is too slow for every UI edit |

**Supported frameworks:** Playwright, Jest, Vitest. Auto-detected from `playwright.config.ts`, `jest.config.ts`, or `vitest.config.ts`.

### Layer 3: Coverage Audit (`audit-e2e-coverage.sh`)

On-demand script that compares your API routes against E2E test specs and reports gaps.

```bash
~/.claude/scripts/audit-e2e-coverage.sh /path/to/project
```

**Example output:**
```
E2E Coverage Audit: backend
================================================

Express API Routes:

  ✅ auth → e2e/auth.spec.ts
  ✅ stories → e2e/stories.spec.ts
  ✅ gifts → e2e/gifts.spec.ts
  ❌ payments → NO E2E SPEC
  ❌ voiceProfiles → NO E2E SPEC

================================================
⚠️  2 route(s) missing E2E coverage
```

**Supported project types:**

| Type | Scans | Matches Against |
|------|-------|-----------------|
| **Express/Node** | `src/routes/*.ts` | `e2e/<route>.spec.ts` |
| **FastAPI/Python** | `app/routers/*.py` | `e2e/<router>.spec.ts` |
| **Next.js** | `app/**/page.tsx` | `e2e/web/<page>.spec.ts` |

---

## Codex Escalation Protocol

When the build hook or test runner reports a failure, Claude follows this decision tree:

```
Hook reports failure
    |
    +-- Read the error + file/line
    |
    +-- Can Claude fix it in <2 minutes?
    |       |
    |      YES --> Fix it. Hook re-verifies on next edit.
    |       |
    |      NO  --> Is it obvious? (typo, missing import, wrong type)
    |               |
    |              YES --> Fix it. One more attempt allowed.
    |               |
    |              NO  --> Escalate to Codex
    |
    +-- Spawn Codex agent in background with:
            - Exact error output
            - Failing test name (if Playwright/Jest)
            - Relevant source files
            - "Diagnose root cause + provide fix with file:line"
            |
            +-- Claude continues working on other tasks
            |
            +-- Codex returns --> Claude implements fix --> Hook re-verifies --> Commit
```

**Codex is also proactively invoked for:**
- Sprints producing >500 lines of new code
- Any security, auth, or payments code changes
- Architecture decisions affecting multiple files
- Flaky or intermittent test failures

---

## How Hooks Work (Technical)

Claude Code hooks are configured in `~/.claude/settings.json`. When Claude uses the `Edit` or `Write` tool, the harness runs the hook command and passes the tool call as JSON on stdin:

```json
{
  "tool_name": "Edit",
  "tool_input": {
    "file_path": "/path/to/file.swift",
    "old_string": "...",
    "new_string": "..."
  },
  "tool_response": { "success": true }
}
```

The script reads `file_path`, detects the project type, runs the check, and returns JSON:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "✅ iOS BUILD SUCCEEDED"
  }
}
```

The `additionalContext` is injected back into Claude's context window, so it immediately sees the result without any user intervention.

---

## File Structure

```
~/.claude/
  settings.json              # Hook configuration (PostToolUse triggers)
  scripts/
    verify-build.sh          # Layer 1: Build/type verification
    run-tests.sh             # Layer 2: Test runner
    audit-e2e-coverage.sh    # Layer 3: Coverage gap reporter
```

---

## Configuration

### Skip verification temporarily

Set an environment variable to disable hooks during rapid iteration:

```bash
export CLAUDE_SKIP_BUILD_VERIFY=true
```

### Customize test triggers

Edit the `if` field in `~/.claude/settings.json` to control which file types trigger the test runner:

```json
{
  "if": "Edit(*.ts)|Edit(*.tsx)|Write(*.ts)|Write(*.tsx)"
}
```

---

## Requirements

| Requirement | What For |
|-------------|----------|
| Claude Code | Hook execution |
| `jq` | Install script (merges settings) |
| Xcode CLI tools | Swift projects (`xcodebuild`) |
| Node.js | TypeScript projects (`npx tsc`) |
| Python 3 | Python projects (`py_compile`) |
| Playwright | E2E tests (`npx playwright test`) |

---

## FAQ

**Q: Will this slow down my Claude Code session?**
A: Build verification adds 5-60 seconds per edit depending on project size. Test running adds 10-30 seconds but only fires on backend route changes, not every edit. Python syntax checks take <1 second.

**Q: What if I don't have Playwright set up?**
A: The test runner exits silently if no `playwright.config.ts` is found. You only get build verification.

**Q: Does this work for monorepos?**
A: Yes. The scripts walk up the directory tree to find the nearest `tsconfig.json`, `.xcodeproj`, or `package.json`.

**Q: Can I use this without Claude Code?**
A: The scripts work standalone. Pipe JSON on stdin or pass a file path as an argument: `echo '{"tool_input":{"file_path":"src/index.ts"}}' | ~/.claude/scripts/verify-build.sh`

---

## License

MIT. Built by [Litson Co](https://github.com/litsonco).
