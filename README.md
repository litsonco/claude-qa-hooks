# Claude Code QA Hooks

**Automated QA, security testing, and human escalation for AI-assisted development.**

A 6-layer quality system that runs inside Claude Code. It type-checks every edit, runs tests on backend changes, blocks dangerous commands, generates security tests from project-specific threat models, runs automated penetration scans, and escalates to senior developers (via email) when AI can't self-fix. Works across Swift, TypeScript, Python, Go, and Rust.

## Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/litsonco/claude-qa-hooks/main/install.sh | bash
```

Then add to `~/.zshrc`:

```bash
export CLAUDE_QA_EMAIL=you@company.com
export CLAUDE_QA_REVIEWER=your-github-handle
export CLAUDE_QA_REPOS='litsonco/repo1,litsonco/repo2'
```

Restart Claude Code. Hooks are global — they fire on every project automatically.

---

## Architecture

```
 ┌─────────────────────────────────────────────────────────────────────────┐
 │                        DEVELOPER EDITS CODE                            │
 │                        via Claude Code                                  │
 └───────────────────────────────┬─────────────────────────────────────────┘
                                 │
         ┌───────────────────────▼───────────────────────┐
         │            LAYER 0: SAFETY GATE               │
         │    PreToolUse — fires BEFORE Bash commands     │
         │                                               │
         │  Blocks: rm -rf, git push --force, DROP TABLE │
         │          git reset --hard, dd of=/dev/,       │
         │          curl|sudo bash, DELETE FROM (no WHERE)│
         └───────────────────────┬───────────────────────┘
                                 │ ALLOWED
         ┌───────────────────────▼───────────────────────┐
         │            LAYER 1: BUILD VERIFY              │
         │    PostToolUse — fires AFTER every edit        │
         │                                               │
         │  .swift → xcodebuild    .ts → tsc --noEmit   │
         │  .py    → py_compile    .go → go vet          │
         │  .rs    → cargo check                         │
         └───────────────────────┬───────────────────────┘
                                 │
                    ┌────────────▼────────────┐
                    │  Route / handler edit?   │
                    └──────┬─────────┬────────┘
                          YES        NO
                           │          │
         ┌─────────────────▼──┐       │
         │  LAYER 2: TESTS    │       │
         │  Playwright E2E    │       │
         │  Jest / Vitest     │       │
         └─────────┬──────────┘       │
                   │                  │
         ┌─────────▼──────────────────▼──┐
         │          PASS or FAIL?         │
         └──────┬─────────────────┬──────┘
               PASS              FAIL
                │                 │
                │      ┌──────────▼──────────┐
                │      │ Claude self-fix     │
                │      │ (< 2 min, obvious)  │
                │      └──────┬──────┬───────┘
                │            FIXED  CAN'T FIX
                │              │       │
                │              │  ┌────▼─────────────┐
                │              │  │ Codex agent       │
                │              │  │ (background)      │
                │              │  └────┬──────┬───────┘
                │              │      FIXED  CAN'T FIX
                │              │        │       │
         ┌──────▼──────────────▼────────▼──┐    │
         │          CONTINUE               │    │
         │          WORKING                │    │
         └─────────────────────────────────┘    │
                                                │
         ┌──────────────────────────────────────▼──────────────────────────┐
         │                    LAYER 4: HUMAN ESCALATION                    │
         │                                                                 │
         │  1. GitHub Issue created (full error + Codex analysis)          │
         │  2. Email sent immediately to CLAUDE_QA_EMAIL                   │
         │  3. macOS notification with sound                               │
         │                                                                 │
         │  If no response in 12h → email reminder + GitHub comment        │
         │  If no response in 24h → email entire team + 'urgent' label     │
         └─────────────────────────────────────────────────────────────────┘

 ┌─────────────────────────────────────────────────────────────────────────┐
 │                     LAYER 3: COVERAGE AUDIT                            │
 │                     (on demand + weekly cron)                           │
 │                                                                         │
 │  Scans all routes → checks for matching E2E specs → reports gaps       │
 │  Scans all specs  → checks 7 security categories → reports gaps        │
 │  Reads threat-model.json → verifies risks have tests → reports gaps    │
 └─────────────────────────────────────────────────────────────────────────┘

 ┌─────────────────────────────────────────────────────────────────────────┐
 │                     LAYER 5: AUTOMATED PENTEST                         │
 │                     (weekly via OWASP ZAP)                              │
 │                                                                         │
 │  Crawls API → fuzzes parameters → tests attack chains → checks CVEs   │
 │  Auto-escalates to email on high-risk findings                         │
 └─────────────────────────────────────────────────────────────────────────┘

 ┌─────────────────────────────────────────────────────────────────────────┐
 │                     THREAT MODEL (per project)                         │
 │                                                                         │
 │  threat-model.json defines project-specific risks:                     │
 │    Clemency: PII, role escalation, legal docs, content moderation      │
 │    ReadBy:   COPPA, voice biometrics, AI prompt injection, family IDOR │
 │                                                                         │
 │  Auto-generated from project docs, data models, and code patterns      │
 │  Drift detection alerts when the model falls behind the code           │
 └─────────────────────────────────────────────────────────────────────────┘

 ┌─────────────────────────────────────────────────────────────────────────┐
 │                     OBSERVABILITY                                       │
 │                                                                         │
 │  qa-log.jsonl ─── every hook result logged ─── flaky test detection    │
 │                                              ─── weekly trend reports   │
 └─────────────────────────────────────────────────────────────────────────┘
```

---

## The Six Layers

### Layer 0: Safety Gate

**PreToolUse hook** — fires *before* Bash commands execute. Blocks destructive operations.

| Blocked | Why |
|---------|-----|
| `rm -rf /`, `rm -rf ~`, `rm -rf .` | Catastrophic file deletion |
| `git push --force` | Overwrites team's remote history |
| `git reset --hard` | Discards uncommitted work permanently |
| `DROP TABLE`, `TRUNCATE`, `DELETE FROM` (no WHERE) | Irreversible data destruction |
| `curl \| sudo bash` | Untrusted remote code execution |
| `dd of=/dev/`, `mkfs` | Disk/filesystem destruction |

### Layer 1: Build Verification

**PostToolUse hook** — fires after every `Edit` or `Write`. Type-checks only (not full builds), fast enough for every edit.

| Language | Tool | Speed |
|----------|------|-------|
| Swift | `xcodebuild` (compile, no signing) | ~30-60s |
| TypeScript | `npx tsc --noEmit` | ~5-15s |
| Python | `python3 -m py_compile` | <1s |
| Go | `go vet ./...` | ~5-15s |
| Rust | `cargo check` | ~10-30s |

### Layer 2: Test Runner

Fires on backend TypeScript/JavaScript edits. Framework auto-detected.

| File Changed | What Runs |
|-------------|-----------|
| `src/routes/*`, `src/handlers/*`, `src/middleware/*` | Playwright E2E (full suite) |
| `src/utils/*` | Jest/Vitest (related tests only) |
| `e2e/*.spec.ts` | Playwright (that spec only) |
| `*.tsx` (frontend) | Type-check only (E2E too slow per edit) |

### Layer 3: Coverage & Security Audit

Three audit scripts that check for gaps:

```bash
# Functional test coverage — which routes have E2E specs?
~/.claude/scripts/audit-e2e-coverage.sh /path/to/project

# Security test coverage — IDOR, injection, race conditions covered?
~/.claude/scripts/security-test-audit.sh /path/to/project

# Threat model freshness — has the code outgrown the threat model?
~/.claude/scripts/threat-model-refresh.sh /path/to/project
```

### Layer 4: Human Escalation + Notifications

When Claude + Codex both fail:

1. **Immediately:** GitHub Issue created + email + macOS notification
2. **12 hours, no response:** Reminder email + GitHub comment
3. **24 hours, no response:** Team-wide email + `urgent` label

### Layer 5: Automated Pentesting

OWASP ZAP via Docker — actual attack simulation beyond what specs can do.

```bash
~/.claude/scripts/pentest-scan.sh --target http://localhost:8001 --scan-type quick   # ~5 min
~/.claude/scripts/pentest-scan.sh --target http://localhost:8001 --scan-type full    # ~30 min
```

Auto-escalates to email on high-risk findings.

---

## Threat Models

Each project has a `threat-model.json` defining its specific risks. This drives security test generation — generic tests plus project-specific tests.

**Example risks by project:**

| Clemency Project | ReadBy / StoryTime |
|------------------|--------------------|
| PII of justice-impacted individuals | Children's data (COPPA regulated) |
| 4-tier role escalation (user → admin) | Family account boundary (cross-family IDOR) |
| Legal document uploads | Voice recording theft (biometric data) |
| Contact form email relay abuse | AI prompt injection in story generation |
| OG image path traversal | Gift code brute force |
| Moderation data leaks | Notification content safety for children |

**Threat models auto-update** as the codebase changes:

```bash
# Generate a threat model from project docs, data models, and code patterns
~/.claude/scripts/threat-model-generator.sh /path/to/project

# Check if the threat model has drifted behind the code
~/.claude/scripts/threat-model-refresh.sh /path/to/project
```

---

## Security Test Framework

Every route gets TWO spec files:

| File | What It Tests |
|------|--------------|
| `route.spec.ts` | Happy paths + basic error cases (does the feature work?) |
| `route.security.spec.ts` | IDOR, injection, race conditions, rate limits, boundary inputs, enumeration, file upload abuse |

Security specs use `e2e/security-helpers.ts` — reusable utilities:

| Helper | What It Tests |
|--------|--------------|
| `testIDOR()` | Can user A access user B's resource? |
| `testInjection()` | SQL, NoSQL, XSS, path traversal, command injection payloads |
| `testConcurrent()` | N simultaneous requests — does data corrupt? |
| `testRateLimit()` | Rapid-fire requests — does 429 kick in? |
| `testOversizedUpload()` | 100MB file upload — crash or reject? |
| `testDisguisedFileType()` | EXE renamed to PDF — detected? |
| `testPathTraversalUpload()` | `../../../etc/passwd` as filename |
| `testEnumeration()` | Do "not found" vs "forbidden" leak existence? |
| `testBoundaryInputs()` | Empty, 10K chars, unicode, null bytes, extreme numbers |

---

## Where Humans Fit In

AI handles the volume. Humans handle the judgment.

| AI Handles Automatically | Humans Handle |
|-------------------------|---------------|
| Type-check every edit | Review threat model severity ratings |
| Run tests on backend changes | Triage flaky tests (real bug or timing?) |
| Block dangerous commands | Prioritize coverage gaps (payments > settings) |
| Generate security tests from threat model | Review new E2E specs for edge cases |
| Detect stale threat models | Add business-context risks code can't detect |
| Send email alerts on failures | Decide when to invest in external pentesting |
| Log trends and detect flaky tests | Monthly tuning — are hooks catching real bugs? |

**CODEOWNERS** auto-requests human review on PRs touching: auth, payments, migrations, deploy configs, Dockerfiles, environment files, and the QA hooks themselves.

---

## Observability

All hooks log to `~/.claude/qa-log.jsonl`:

```bash
# Flaky test detection
~/.claude/scripts/flaky-test-detector.sh --days 7

# Weekly coverage + health report across all projects
~/.claude/scripts/weekly-coverage-audit.sh --projects "$CLAUDE_QA_PROJECTS"
```

---

## File Structure

```
~/.claude/
  settings.json                          # Hook configuration
  qa-log.jsonl                           # All hook results (append-only)
  scripts/
    safety-gate.sh                       # Layer 0: Block destructive commands
    verify-build.sh                      # Layer 1: Build/type verification
    run-tests.sh                         # Layer 2: Test runner
    audit-e2e-coverage.sh                # Layer 3: Functional test coverage
    security-test-audit.sh               # Layer 3: Security test coverage
    threat-model-refresh.sh              # Layer 3: Threat model drift detection
    escalate-to-human.sh                 # Layer 4: GitHub Issues + email
    notify-human.sh                      # Layer 4: Multi-channel notifications
    stale-issue-checker.sh               # Layer 4: 12h/24h reminder cron
    pentest-scan.sh                      # Layer 5: OWASP ZAP scanning
    threat-model-generator.sh            # Context-aware threat model generation
    flaky-test-detector.sh               # Observability: flaky test detection
    weekly-coverage-audit.sh             # Observability: weekly reports
    com.litsonco.qa-stale-checker.plist  # macOS launchd for stale checker

Project root:
  threat-model.json                      # Project-specific security risks
  CODEOWNERS                             # Auto-review for sensitive paths
  e2e/
    helpers.ts                           # Standard test helpers
    security-helpers.ts                  # Security test utilities
    *.spec.ts                            # Functional E2E specs
    *.security.spec.ts                   # Security E2E specs
```

---

## Configuration

| Variable | Purpose | Default |
|----------|---------|---------|
| `CLAUDE_QA_EMAIL` | Where to send alerts | (required) |
| `CLAUDE_QA_REVIEWER` | GitHub handle for issue assignment | (required) |
| `CLAUDE_QA_REPOS` | Repos to monitor for stale issues | (required) |
| `CLAUDE_QA_PROJECTS` | Project dirs for weekly audit | (optional) |
| `CLAUDE_QA_EMAIL_CC` | CC on escalation emails | (optional) |
| `CLAUDE_QA_LABELS` | Issue labels | `qa-hook,needs-human` |
| `CLAUDE_QA_LOG` | Log file location | `~/.claude/qa-log.jsonl` |
| `CLAUDE_SKIP_BUILD_VERIFY` | Disable build verification | `false` |
| `CLAUDE_SKIP_TESTS` | Disable test runner | `false` |
| `CLAUDE_SKIP_SAFETY_GATE` | Disable safety gate | `false` |
| `SENDGRID_API_KEY` | Email delivery | (falls back to system mail) |

---

## Requirements

| Tool | What For | Required? |
|------|----------|-----------|
| Claude Code | Hook execution | Yes |
| `jq` | JSON processing | Yes |
| `gh` CLI | Issue creation, stale checking | Yes |
| Docker | OWASP ZAP pentesting | For Layer 5 only |
| Xcode, Node, Python, Go, Cargo | Language-specific type checking | Only for your languages |
| Playwright, Jest, Vitest | Test execution | Only if tests exist |

---

## FAQ

**Q: Will this slow down my Claude Code session?**
Build verification adds 1-60 seconds per edit (Python <1s, Swift ~60s). Tests add 10-30 seconds but only fire on backend route changes. Safety gate adds <100ms.

**Q: What if Codex can't fix it either?**
Layer 4 creates a GitHub Issue, sends you an email immediately, and reminds you at 12h and 24h if you haven't responded.

**Q: How do I add support for another language?**
Add an `if [ "$EXT" = "xyz" ]` block in `verify-build.sh`. Use the Go/Rust blocks as templates.

**Q: Does this work for monorepos?**
Yes. Scripts walk up the directory tree to find the nearest config file.

**Q: How does the threat model stay current?**
Three mechanisms: (1) Claude updates it when adding routes/features, (2) `threat-model-refresh.sh` detects drift, (3) `threat-model-generator.sh` rebuilds it from project docs and code.

**Q: What's the difference between the security specs and the pentest?**
Security specs test specific patterns (IDOR, injection, race conditions) in your test suite. The pentest (ZAP) crawls your live API and tries real attacks — it finds misconfigurations, header issues, and attack chains that specs don't compose.

---

## License

MIT. Built by [Litson Co](https://github.com/litsonco).
