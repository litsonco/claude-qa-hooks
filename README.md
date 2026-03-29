# Claude Code QA Hooks

**Automated build verification, test running, safety gating, and human escalation for Claude Code.**

Catches compilation errors the moment they're introduced, runs E2E tests on backend changes, blocks destructive commands before they execute, and escalates to senior developers when AI can't self-fix. Works across Swift, TypeScript, Python, Go, Rust, and any Xcode/Node/Python/Go/Cargo project.

## Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/litsonco/claude-qa-hooks/main/install.sh | bash
```

Then restart Claude Code.

> **Note:** The installer **appends** to your existing `~/.claude/settings.json` hooks — it will never overwrite your existing configuration. Requires `jq`.

---

## Architecture

```
                         You edit code via Claude Code
                                    |
                    +-------------------------------+
                    |       LAYER 0: SAFETY GATE     |
                    |  PreToolUse — blocks dangerous  |
                    |  Bash commands before execution  |
                    +-------------------------------+
                                    |
                                 ALLOWED
                                    |
                    +-------------------------------+
                    |     PostToolUse Hook Fires     |
                    |   (after every Edit / Write)   |
                    +-------------------------------+
                                    |
                         What file was edited?
                                    |
         +----------+----------+----------+----------+----------+
         |          |          |          |          |          |
    .swift      .ts/.tsx      .py        .go        .rs     other
         |          |          |          |          |          |
         v          v          v          v          v          |
  +-----------+ +--------+ +--------+ +--------+ +--------+   |
  | xcodebuild| |  tsc   | |py_comp.| |go vet  | |cargo   |   |
  | (compile) | |(types) | |(syntax)| |(vet)   | |(check) |   |
  +-----------+ +--------+ +--------+ +--------+ +--------+   |
         |          |          |          |          |          |
         |     Route/handler?  |          |          |          |
         |     +----+----+     |          |          |          |
         |    YES       NO     |          |          |          |
         |     |         |     |          |          |          |
         |     v         |     |          |          |          |
         | +----------+  |     |          |          |          |
         | |Playwright|  |     |          |          |          |
         | |Jest/Vite |  |     |          |          |          |
         | +----------+  |     |          |          |          |
         |     |         |     |          |          |          |
         +--+--+---------+-----+----------+----------+----------+
            |            |
         PASSED        FAILED
            |            |
            v            v
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
                                Codex returns fix?
                                   |          |
                                  YES         NO
                                   |          |
                                   v          v
                            +---------+  +------------------------+
                            |Implement|  | LAYER 4: ESCALATE      |
                            |fix, hook|  | TO HUMAN               |
                            |re-runs  |  | → GitHub Issue created  |
                            +---------+  | → Senior dev assigned   |
                                         | → Full context attached |
                                         +------------------------+
```

All results are logged to `~/.claude/qa-log.jsonl` for trend analysis and flaky test detection.

---

## The Five Layers

### Layer 0: Safety Gate (`safety-gate.sh`) — NEW

**PreToolUse hook** that fires *before* Bash commands execute. Blocks destructive operations:

| Pattern | What's Blocked | Why |
|---------|---------------|-----|
| `rm -rf /`, `rm -rf ~` | Broad recursive deletes | Prevents catastrophic file loss |
| `git push --force` | Force push to remote | Can overwrite team's work; use `--force-with-lease` |
| `git reset --hard` | Hard reset | Discards uncommitted changes permanently |
| `git clean -f` | Force clean untracked | Permanently deletes untracked files |
| `DROP TABLE`, `TRUNCATE` | Database destruction | Irreversible data loss |
| `DELETE FROM x` (no WHERE) | Full table delete | Almost always a mistake |
| `curl ... \| sudo bash` | Piped script execution | Download and inspect first |
| `dd ... of=/dev/` | Raw device writes | Can overwrite entire disks |
| `mkfs` | Filesystem format | Destroys all data on device |

Set `CLAUDE_SKIP_SAFETY_GATE=true` to disable temporarily.

### Layer 1: Build Verification (`verify-build.sh`)

Fires after every `Edit` or `Write` on source files. Detects the project type from the file extension and runs the fastest possible compilation check.

| File Type | What Runs | What It Catches | Speed |
|-----------|-----------|-----------------|-------|
| `.swift` | `xcodebuild` (generic iOS, no signing) | Type errors, missing imports, protocol conformance | ~30-60s |
| `.ts` / `.tsx` | `npx tsc --noEmit` | Type errors, interface mismatches, import issues | ~5-15s |
| `.py` | `python3 -m py_compile` | Syntax errors, indentation issues | <1s |
| `.go` | `go vet ./...` | Type errors, suspicious constructs, common mistakes | ~5-15s |
| `.rs` | `cargo check` | Type errors, borrow checker, lifetime issues | ~10-30s |

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

**Supported frameworks:** Playwright, Jest, Vitest (with `--related` file targeting). Auto-detected from config files.

**Note:** Type-checking is handled by Layer 1 (`verify-build.sh`). The test runner does not duplicate the tsc call.

### Layer 3: Coverage Audit (`audit-e2e-coverage.sh`)

On-demand script that compares your API routes against E2E test specs and reports gaps.

```bash
~/.claude/scripts/audit-e2e-coverage.sh /path/to/project
~/.claude/scripts/audit-e2e-coverage.sh --json /path/to/project  # For scripting
~/.claude/scripts/audit-e2e-coverage.sh --help
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

### Layer 4: Human Escalation (`escalate-to-human.sh`) — NEW

When Claude + Codex both fail to resolve an issue, this script creates a GitHub Issue with full context for senior developer review.

```bash
# Automatic (called by Claude's escalation protocol):
~/.claude/scripts/escalate-to-human.sh \
    --error "error output here" \
    --file "/path/to/failing/file.ts" \
    --codex "Codex analysis here" \
    --type build-failure

# Preview without creating:
~/.claude/scripts/escalate-to-human.sh --dry-run \
    --error "..." --file "..." --type security-review
```

**Escalation types:**

| Type | When | Label |
|------|------|-------|
| `build-failure` | Build hook fails, Claude + Codex can't fix | `qa-hook,needs-human` |
| `test-failure` | Tests fail, Claude + Codex can't fix | `qa-hook,needs-human` |
| `security-review` | Auth/payment/secrets code was changed | `qa-hook,needs-human,security` |
| `architecture-review` | Multi-file changes (>5 files) | `qa-hook,needs-human,architecture` |

**Configuration:**
```bash
export CLAUDE_QA_REVIEWER=github-handle    # Auto-assign issues
export CLAUDE_QA_LABELS=qa-hook,needs-human  # Custom labels
```

---

## Where Senior Developers Fit In

The QA hooks create a 5-layer system where AI handles routine checks and humans focus on judgment calls:

```
Layer 0 (Safety Gate)     → Automatic — blocks dangerous commands
Layer 1 (Build Verify)    → Automatic — catches type/compile errors
Layer 2 (Test Runner)     → Automatic — runs relevant tests
Layer 3 (Coverage Audit)  → Weekly — humans prioritize gaps
Layer 4 (Human Escalation) → On-demand — AI can't fix, human steps in
```

### When Humans Are Involved

| Trigger | What Happens | How |
|---------|-------------|-----|
| **Codex fails twice** | GitHub Issue created with full error context | `escalate-to-human.sh` |
| **Security code changed** | PR auto-requests review from CODEOWNERS | `CODEOWNERS` file |
| **>500 lines in a sprint** | Architecture review requested | Codex proactive invocation |
| **Flaky test detected** | Issue filed after 3 flips in 7 days | `flaky-test-detector.sh --escalate` |
| **Weekly coverage audit** | Report posted for team triage | `weekly-coverage-audit.sh` |
| **New E2E spec by Claude** | Marked for human review | `// NEEDS-HUMAN-REVIEW` convention |

### What Humans Review (Priority Order)

1. **New E2E specs** — Claude writes good happy-path tests but misses edge cases, race conditions, and security assertions
2. **Multi-file architecture** — When Claude touches 5+ files, review the *design*, not just correctness
3. **Flaky test triage** — Only domain experts can distinguish real bugs from timing issues
4. **Coverage gap prioritization** — Decide which gaps matter (payments > settings page)
5. **Monthly QA tuning** — Review `qa-log.jsonl` trends. Are hooks catching real bugs or noise?

### CODEOWNERS

The included `CODEOWNERS` file auto-requests review when PRs touch:
- Auth, sessions, permissions, tokens
- Payments, billing, Stripe
- Dockerfiles, CI/CD, deploy scripts
- Database migrations
- Environment/secrets files
- The QA hooks themselves

Edit `CODEOWNERS` to set your team's GitHub handles.

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
            |
            +-- Codex returns fix --> Claude implements --> Hook re-verifies --> Commit
            |
            +-- Codex fails --> ESCALATE TO HUMAN (Layer 4)
                                → GitHub Issue with full context
                                → Senior dev assigned
```

**Codex is also proactively invoked for:**
- Sprints producing >500 lines of new code
- Any security, auth, or payments code changes
- Architecture decisions affecting multiple files
- Flaky or intermittent test failures

---

## Analysis Tools

### Flaky Test Detector (`flaky-test-detector.sh`) — NEW

Analyzes `~/.claude/qa-log.jsonl` to find tests that flip between pass/fail:

```bash
~/.claude/scripts/flaky-test-detector.sh                  # Last 7 days, threshold 3
~/.claude/scripts/flaky-test-detector.sh --days 30         # Last 30 days
~/.claude/scripts/flaky-test-detector.sh --json            # Machine-readable output
~/.claude/scripts/flaky-test-detector.sh --escalate        # Auto-create issues for flaky tests
```

**Example output:**
```
📊 QA Flaky Test Report (last 7 days)
================================================

Summary:
  Total hook runs:  142
  Passed:           128
  Failed:           14
  Escalations:      2

🔄 Flaky Files (pass + fail within 7 days):
  ⚠️  src/routes/payments.ts  (8x pass, 3x fail)

🔴 Chronic Failures (≥3 failures in 7 days):
  ❌ src/middleware/auth.ts  (5 failures)
```

### Weekly Coverage Audit (`weekly-coverage-audit.sh`) — NEW

Runs coverage audits across multiple projects and generates a report:

```bash
# On-demand
~/.claude/scripts/weekly-coverage-audit.sh \
    --projects /path/to/proj1,/path/to/proj2

# Post to GitHub Discussions
~/.claude/scripts/weekly-coverage-audit.sh \
    --projects "$CLAUDE_QA_PROJECTS" \
    --output github --repo litsonco/claude-qa-hooks

# Write to file (for cron)
~/.claude/scripts/weekly-coverage-audit.sh \
    --projects "$CLAUDE_QA_PROJECTS" \
    --output file
```

**Cron setup (Monday 8am):**
```bash
0 8 * * 1 CLAUDE_QA_PROJECTS="/path/to/proj1,/path/to/proj2" ~/.claude/scripts/weekly-coverage-audit.sh --output file
```

---

## QA Log (`qa-log.jsonl`)

All hooks append structured JSON to `~/.claude/qa-log.jsonl`:

```jsonl
{"timestamp":"2026-03-29T10:15:00Z","hook":"verify-build","file":"/path/to/file.ts","status":"pass","lang":"typescript","detail":"no errors"}
{"timestamp":"2026-03-29T10:16:00Z","hook":"run-tests","file":"/path/to/file.ts","status":"fail","framework":"playwright","detail":"2/15 failed"}
{"timestamp":"2026-03-29T10:20:00Z","hook":"safety-gate","command":"git reset --hard","action":"blocked","reason":"BLOCKED: git reset --hard discards uncommitted changes"}
{"timestamp":"2026-03-29T10:25:00Z","hook":"escalate-to-human","file":"/path/to/file.ts","type":"build-failure","issue":"https://github.com/..."}
```

**Customize location:** `export CLAUDE_QA_LOG=/path/to/custom-log.jsonl`

---

## How Hooks Work (Technical)

Claude Code hooks are configured in `~/.claude/settings.json`. The harness passes tool call data as JSON on stdin:

**PreToolUse** (before execution — safety gate):
```json
{
  "tool_name": "Bash",
  "tool_input": { "command": "git reset --hard" }
}
```

Returns `decision: "block"` to prevent execution, or exits 0 to allow.

**PostToolUse** (after execution — build verify + tests):
```json
{
  "tool_name": "Edit",
  "tool_input": { "file_path": "/path/to/file.swift", "old_string": "...", "new_string": "..." },
  "tool_response": { "success": true }
}
```

Returns `additionalContext` which is injected back into Claude's context window.

---

## File Structure

```
~/.claude/
  settings.json              # Hook configuration (Pre/PostToolUse triggers)
  qa-log.jsonl               # Append-only log of all hook results
  scripts/
    safety-gate.sh           # Layer 0: Block destructive Bash commands
    verify-build.sh          # Layer 1: Build/type verification
    run-tests.sh             # Layer 2: Test runner
    audit-e2e-coverage.sh    # Layer 3: Coverage gap reporter
    escalate-to-human.sh     # Layer 4: Human escalation via GitHub Issues
    flaky-test-detector.sh   # Analysis: Flaky test detection from QA log
    weekly-coverage-audit.sh # Cron: Weekly multi-project coverage report

Project root:
  CODEOWNERS                 # Auto-request review for security-sensitive paths
```

---

## Configuration

### Environment Variables

| Variable | Purpose | Default |
|----------|---------|---------|
| `CLAUDE_SKIP_BUILD_VERIFY` | Skip build verification | `false` |
| `CLAUDE_SKIP_TESTS` | Skip test runner | `false` |
| `CLAUDE_SKIP_SAFETY_GATE` | Skip safety gate | `false` |
| `CLAUDE_QA_LOG` | QA log file location | `~/.claude/qa-log.jsonl` |
| `CLAUDE_QA_REVIEWER` | GitHub handle for issue assignment | (none) |
| `CLAUDE_QA_LABELS` | Labels for escalation issues | `qa-hook,needs-human` |
| `CLAUDE_QA_PROJECTS` | Comma-separated project dirs for weekly audit | (none) |

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
| `jq` | JSON processing (install + all scripts) |
| Xcode CLI tools | Swift projects (`xcodebuild`) |
| Node.js | TypeScript projects (`npx tsc`) |
| Python 3 | Python projects (`py_compile`) |
| Go | Go projects (`go vet`) |
| Rust/Cargo | Rust projects (`cargo check`) |
| Playwright | E2E tests (`npx playwright test`) |
| `gh` CLI | Human escalation + weekly reports |

Only the tools for your project type are needed — the scripts detect what's available and skip gracefully.

---

## FAQ

**Q: Will this slow down my Claude Code session?**
A: Build verification adds 1-60 seconds per edit depending on language and project size (Python <1s, Rust ~30s). Tests add 10-30 seconds but only fire on backend route changes. The safety gate adds <100ms.

**Q: What if I don't have Playwright set up?**
A: The test runner exits silently if no `playwright.config.ts` is found. You only get build verification.

**Q: What if Codex can't fix it either?**
A: Layer 4 kicks in — `escalate-to-human.sh` creates a GitHub Issue with the full error output, Codex analysis, and file context, then assigns it to your configured reviewer.

**Q: Does this work for monorepos?**
A: Yes. The scripts walk up the directory tree to find the nearest `tsconfig.json`, `.xcodeproj`, `go.mod`, `Cargo.toml`, or `package.json`.

**Q: Can I use this without Claude Code?**
A: The scripts work standalone. Pipe JSON on stdin or pass a file path as an argument: `echo '{"tool_input":{"file_path":"src/index.ts"}}' | ~/.claude/scripts/verify-build.sh`

**Q: How do I add support for another language?**
A: Add a new `if [ "$EXT" = "xyz" ]` block in `verify-build.sh`. Use the `find_up`, `emit`, and `log_result` helpers for consistency. See the Go/Rust blocks as templates.

**Q: Will the installer overwrite my existing hooks?**
A: No. The installer checks for existing hook entries by command path and only appends new ones. Your existing hooks, plugins, and MCP servers are preserved.

**Q: How do I see what the hooks have been doing?**
A: Run `flaky-test-detector.sh` for a summary, or inspect `~/.claude/qa-log.jsonl` directly. Each line is a JSON object with timestamp, hook name, file, status, and details.

---

## License

MIT. Built by [Litson Co](https://github.com/litsonco).
