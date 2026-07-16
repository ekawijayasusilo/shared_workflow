# RFC 0001: Triage-based PR review with `ce-code-review` in the opencode review workflow

- **Status:** Approved — implemented 2026-07-16
- **Date:** 2026-07-16
- **Authors:** Eka Wijaya Susilo (requirements, decisions), Claude (research, drafting)
- **Reviewers:** AI review pass completed 2026-07-16; all findings resolved in v2 (see Section 7)

## 1. Background

This repository (`ekawijayasusilo/shared_workflow`) hosts centralized reusable GitHub Actions workflows. Consumer repos keep only tiny caller stubs that track `@main`.

One of these workflows is the automatic PR reviewer:

- **Caller stub** (`stubs/opencode-review.yml`, copied into each consumer repo): triggers on `pull_request` (`opened`, `synchronize`, `reopened`, `ready_for_review`), guarded by `if: github.event.pull_request.draft == false`, and calls the reusable workflow, passing the `OPENCODE_API_KEY` secret.
- **Reusable workflow** (`.github/workflows/opencode-review.reusable.yml`): checks out the repo, then runs the opencode GitHub Action `anomalyco/opencode/github@10c894bdeef3618f5666fb506ef7f9491bb964d8` (SHA-pinned, v1.17.13) with:
  - `model: opencode-go/deepseek-v4-pro`, `variant: max`, `use_github_token: true`
  - a **hardcoded generalist review prompt**: review only changed lines, report findings as inline comments tagged `[BLOCKER]/[HIGH]/[MEDIUM]/[LOW]`, prioritize correctness > concurrency > security > API design > tests, skip style, end with a summary and an APPROVE / REQUEST CHANGES / COMMENT verdict.
- **Permissions:** `contents: read`, `pull-requests: write`, `issues: write`, `id-token: write`. The review job cannot push code today.

Separately, the repo recently added `.github/workflows/opencode-doc-management.reusable.yml`, which loads the [compound-engineering plugin](https://github.com/EveryInc/compound-engineering-plugin) into opencode via the `OPENCODE_CONFIG_CONTENT` environment variable. The review workflow does **not** load that plugin yet.

## 2. What the user wants

Improve the review workflow so it uses the compound-engineering **`ce-code-review`** skill, with two hard constraints ("catches") and one open question:

1. **Report-only.** The review must only post its results as GitHub PR comments. It must never apply fixes, commit, or push.
2. **Intelligent mode selection.** opencode must decide per-PR between two review depths, by reading the PR title, description, and the changes themselves:
   - **Complex mode** — the full multi-subagent `ce-code-review` pipeline — for complicated/risky PRs: new feature additions of meaningful size, architectural changes, design-pattern changes, new libraries and their usage, large line/file counts, complicated refactoring.
   - **Quick mode** — a lightweight review — for simple bug fixes, small feature tweaks, small diffs under some threshold of changed lines/files, and other minor changes.
3. **Open question from the user:** can the hardcoded prompt in the workflow be simplified, given that `ce-code-review` carries its own review rubric?

The user initially assumed the quick mode could be `ce-code-review`'s own built-in quick path, which forwards to the harness-native `/review` command. Section 3 explains why that exact mechanism does not work under constraint 1, and Section 5 shows what was chosen instead.

## 3. Verified technical facts

Every claim below was verified against the named source, not assumed.

### 3.1 `ce-code-review` mode and depth matrix

Source: [`skills/ce-code-review/SKILL.md`](https://github.com/EveryInc/compound-engineering-plugin/blob/main/skills/ce-code-review/SKILL.md) — the authoritative skill contract. (An earlier draft of this RFC cited the plugin's `docs/` page, which lagged the skill contract; claims below were re-verified against SKILL.md.)

**Modes:**

| Mode | Mutates code? | Quick-review short-circuit? |
| --- | --- | --- |
| Interactive (default) | **Yes** — applies safe verified fixes and commits them (`fix(review):`) on a clean tree; never pushes | Yes — "quick/fast/light" requests defer to the harness-native review |
| `mode:agent` (alias `mode:headless`) | No — emits one JSON findings report, mutates nothing; the caller applies/posts | No — the short-circuit to harness-native review is bypassed |

**Depths** (orthogonal to mode — `mode:agent` "does not change reviewer selection"):

| Depth | Behavior |
| --- | --- |
| `depth:auto` (default) | Self-right-sizes via the Stage 3c small-diff fast path: for trivial, low-risk, code-only diffs the reviewer roster collapses to a **lite roster** (inline fast pass + `correctness-reviewer` + `project-standards-reviewer`); otherwise the full roster runs |
| `depth:full` | Forces the full roster; disables Stage 3c |

**The Stage 3c lite gate is deliberately fail-closed and narrow.** The lite roster fires only when **all** of these hold:

- fewer than 40 changed executable lines (added + deleted, counted over code files only),
- **zero** changed non-code files — any Markdown, config, CI, lockfile, schema, or shell file disqualifies the lite path,
- no content risk signals (auth, payments, data mutation),
- the diff base resolved cleanly (any counting uncertainty forces the full roster).

**Consequences for this design:**

1. `mode:agent depth:auto` satisfies report-only **and** self-right-sizes — but only within that narrow gate. This RFC's SIMPLE bucket (Section 5.3) is much wider: docs/config-only changes and diffs up to ~100 lines all **fail** the lite gate (non-code files disqualify; ≥40 exec lines disqualify) and would run the full 6+ subagent roster.
2. Therefore a single always-`mode:agent depth:auto` path cannot deliver the intended cheap quick mode, and the quick/complex routing must live **outside** the skill, in the workflow prompt. Within the COMPLEX path, `depth:auto` is kept as a free second-layer right-sizer for borderline PRs that triage over-classifies.
3. Interactive mode is unusable regardless: it applies fixes and commits, violating report-only.

### 3.2 opencode's native review command is not agent-invocable in CI

opencode ships a native review command template ([`packages/opencode/src/command/template/review.txt`](https://github.com/anomalyco/opencode/blob/dev/packages/opencode/src/command/template/review.txt)) — a solid lean rubric that reads full files, focuses on real bugs, and accepts a PR number as input. However, command templates are expanded when a *user* types `/review`; the agent running inside `opencode github run` cannot self-invoke slash commands. A quick-path review in CI must therefore be expressed as inline instructions in the workflow prompt (functionally equivalent to the template).

### 3.3 Plugin loading in the GitHub Action

- The action ([`github/action.yml`](https://github.com/anomalyco/opencode/blob/dev/github/action.yml)) has **no plugin/skill inputs**. Its inputs are only: `model`, `agent`, `share`, `prompt`, `use_github_token`, `mentions`, `variant`, `oidc_base_url`.
- Plugins load through opencode's normal config discovery. The chosen mechanism is the **`OPENCODE_CONFIG_CONTENT` environment variable** (inline JSON config). Verified in [`packages/opencode/src/config/config.ts`](https://github.com/anomalyco/opencode/blob/dev/packages/opencode/src/config/config.ts): it is **merged** on top of global + project config as "local" scope — a consumer repo's own `opencode.json` still applies.
- The plugin reference is deliberately **unpinned** (`git+https://github.com/EveryInc/compound-engineering-plugin.git`, no `#tag`) per the user's standing decision: every run picks up the latest plugin. Accepted tradeoff: an upstream breaking change (including changes to `ce-code-review`'s routing rules or `mode:agent` JSON contract) lands in CI without action on our side. The pinned action itself also installs the latest opencode runtime at run time, so both upstreams move.
- Skills register as **tools** in opencode sessions, so the workflow prompt can instruct the agent to invoke `ce-code-review` with `mode:agent`.

### 3.4 CI-environment degradations (acceptable)

- `ce-code-review`'s cross-model adversarial pass wants a second provider CLI (codex/grok/cursor) which does not exist on the GitHub runner. The pass is detached and non-blocking; it degrades silently. No mitigation needed.
- The plugin is fetched by Bun at session startup on every run (no cache, by design, to honor "always latest").

### 3.5 Fork and bot PRs

Fork PRs do not receive repository secrets, and Dependabot-authored PRs run under the same restriction — on such PRs the action would start without a usable `OPENCODE_API_KEY` and fail cryptically. The review job must be skipped for them (see Section 5.2).

## 4. Options considered

### Option 1 — Triage in the workflow prompt (**decided**)

The workflow prompt instructs the agent to first classify the PR as COMPLEX or SIMPLE from its title, description, diff stats, and a skim of the diff. Then:

- **COMPLEX** → invoke `ce-code-review` with `mode:agent` (report-only JSON; default `depth:auto` retained as internal right-sizing), then post the findings as PR comments.
- **SIMPLE** → the agent reviews the diff itself against a lean inline rubric and posts comments directly.

**Pros:** satisfies both constraints; pushes are impossible at the token level (`contents: read`) and all other mutation is explicitly prohibited in the prompt; full-pipeline cost (6+ subagents) only paid on genuinely complex PRs; semantic triage (architecture, risk, new dependencies) as the user asked, with numeric thresholds only as guidance.

**Cons:** triage quality depends on prompt criteria; two rubric sources exist (skill rubric for complex, inline lean rubric for simple) which could drift in tone/severity conventions — mitigated by mandating the same P0–P3 scale and the same severity→verdict mapping for both paths.

### Option 2 — Always run `ce-code-review mode:agent depth:auto` (rejected)

Simplest prompt, consistent output shape, and the skill's Stage 3c would right-size *some* runs. Rejected because the lite gate is far narrower than the intended quick bucket (Section 3.1): docs/config-only PRs and simple <100-line fixes would routinely run the full multi-persona pipeline — cost and latency waste that defeats constraint 2. The gate is upstream's and fail-closed by design; it is not tunable from our side (`depth:` accepts only `auto`/`full`).

### Option 3 — Interactive mode relying on the skill's built-in quick short-circuit (rejected)

This is the mechanism the user originally had in mind. Rejected because interactive mode applies fixes and commits, violating constraint 1 (report-only), and would additionally require `contents: write`.

### Option 4 — Deterministic pre-step triage (rejected)

A bash pre-step computes `git diff --stat` thresholds and interpolates COMPLEX/SIMPLE into the prompt. Reproducible, but pure LoC/file-count thresholds cannot capture what the user explicitly asked triage to detect: architectural changes, design-pattern changes, new libraries, risky refactors. Agent-side triage subsumes numeric thresholds as guidance while adding semantic judgment.

## 5. Decided design

### 5.1 Answer to the prompt-simplification question

The prompt gets **restructured, not shortened**. The complex path delegates its entire rubric to the skill (two lines in the prompt). The quick path still needs its own lean rubric because it never enters the skill. Add triage criteria and posting instructions, and net length stays similar — but rubric duplication with the skill is gone from the complex path, and the skill remains the single source of truth for deep reviews.

### 5.2 Workflow changes to `.github/workflows/opencode-review.reusable.yml`

1. Add a job-level guard so the review only runs on non-draft, same-repository, human-authored PRs (fork/bot PRs would start without usable secrets — Section 3.5):

   ```yaml
   if: >
     github.event.pull_request.draft == false &&
     github.event.pull_request.head.repo.full_name == github.repository &&
     github.event.pull_request.user.type != 'Bot'
   ```

   The stub keeps its existing draft guard; the reusable workflow's guard is the centralized defense.

2. Add `OPENCODE_CONFIG_CONTENT` to the action step's `env` (same pattern as the doc-management workflow):

   ```json
   {
     "plugin": ["compound-engineering@git+https://github.com/EveryInc/compound-engineering-plugin.git"]
   }
   ```

3. Replace the hardcoded prompt with the triage prompt below.
4. **Remove `id-token: write`** from permissions: the action documents that `use_github_token: true` skips OIDC and uses `GITHUB_TOKEN` directly, so the OIDC permission serves nothing here. Keep `contents: read`, `pull-requests: write`, `issues: write` (PR summary comments post through the issues API).
5. No changes to caller stubs or consumer repos — the improvement propagates via `@main`.

### 5.3 Proposed replacement prompt

```text
You are reviewing a pull request. You must never modify the repository: do not
edit files, do not run git commit, push, or branch commands, do not create,
close, or edit issues or the PR itself. Your only output is review comments
posted on this PR.

Step 1 — Triage. Read the PR title, description, and diff stats (files changed,
lines changed), and skim the diff. Classify:

- COMPLEX if ANY semantic trigger applies, regardless of diff size:
  architectural or design-pattern changes, new library/dependency and its
  usage, schema/migration changes, auth/security-sensitive code,
  concurrency/async changes, public API contract changes, non-trivial
  refactoring, or a new feature of meaningful size. Also COMPLEX on size
  alone: roughly >300 changed lines or >10 files.
- SIMPLE only when no semantic trigger applies and the diff is small: small
  bug fixes, minor tweaks, docs/config-only changes, mechanical renames,
  roughly <100 lines across a few files.
- When it is borderline on size alone (no semantic trigger, roughly 100-300
  lines), prefer SIMPLE.

Step 2 — Review.
- If COMPLEX: invoke the ce-code-review skill with mode:agent on this PR
  (leave depth at its default). It returns a findings report and changes
  nothing. If the skill is unavailable or fails, review the diff yourself
  using the SIMPLE instructions below, but treat the run as COMPLEX-DEGRADED:
  state the failure reason in the summary comment and never give an APPROVE
  verdict.
- If SIMPLE: review the diff yourself. Focus on real bugs: logic errors, wrong
  null/error handling, edge cases, races, security issues, leaked secrets.
  Read the full files you comment on, not just the diff. Only flag issues you
  are confident are real; skip style/formatting.

Step 3 — Post results. For each finding that anchors to a changed line, post
an inline PR comment at file:line with severity (P0 critical / P1 high / P2
medium / P3 low), the concrete problem, and a suggested fix. Findings that
cannot be anchored to a changed line go in the summary comment instead.
Then post one summary comment containing: a 2-3 line overview; which review
mode ran (COMPLEX, SIMPLE, or COMPLEX-DEGRADED) and why; and a verdict:
- REQUEST CHANGES if any P0 or P1 finding exists
- COMMENT if only P2/P3 findings exist
- APPROVE only if no actionable findings remain (never when COMPLEX-DEGRADED)
If the PR is solid, say so briefly — do not invent findings.
```

## 6. Verification plan

1. Merge the workflow change to `main` (callers track `@main`, so it goes live immediately).
2. In a consumer repo, open two test PRs:
   - a trivial one (docs tweak or a few-line bug fix) — expect the **SIMPLE** path: no subagent dispatch in the action logs, direct review comments, summary discloses SIMPLE.
   - a feature-shaped one (new module, new dependency, or >300 changed lines) — expect the **COMPLEX** path: plugin install and `ce-code-review` invocation visible in logs, findings posted as inline comments, summary discloses COMPLEX.
3. In both cases, confirm the action log shows the compound-engineering plugin installing at startup, and confirm the agent pushed **no commits** to the PR branch.
4. If a Dependabot or fork PR is available, confirm the review job is skipped by the Section 5.2 guard rather than failing.

## 7. Review resolution (2026-07-16)

An external AI review of v1 produced 3 BLOCKER and 6 SHOULD-FIX findings. Resolution:

| Finding | Decision |
| --- | --- |
| B1: "`mode:agent` always runs the full pipeline" was stale — current skill has `depth:auto`/Stage 3c lite path | **Accepted (fact fix).** Section 3.1 rewritten against SKILL.md. Reviewer's proposed single-path `depth:auto` architecture **rejected**: lite gate far narrower than the intended SIMPLE bucket (Section 3.1, Option 2). Prompt-level triage retained; `depth:auto` kept inside the COMPLEX path |
| B2: report-only not structurally enforced (local edits, injection-driven mutations) | **Partially accepted.** Prompt prohibition made explicit and enumerated (no edits, no git mutation commands, no issue/PR mutations). Mechanical clean-tree assertion and tokenless-posting split **declined** by the user — prompt-level enforcement plus `contents: read` accepted as sufficient for this project |
| B3: failed deep review could emit a misleading APPROVE | **Accepted.** COMPLEX-DEGRADED labeling, mandatory failure disclosure, APPROVE prohibited. Mechanical CI failure **rejected**: the agent cannot reliably control the job exit code from inside `opencode github run` |
| S1: fork/Dependabot PRs start without secrets | **Accepted.** Job-level guard in the reusable workflow (Section 5.2). Vendor-account denylist deferred until a real need appears |
| S2: unpinned plugin needs canary + smoke tests | **Declined by user.** Unpinned stays; both moving upstreams documented (Section 3.3); the verification plan's test PRs serve as the smoke test |
| S3: `id-token: write` unused under `use_github_token: true` | **Accepted.** Removed (Section 5.2) |
| S4: triage categories overlap; borderline bias under-reviews risk | **Accepted (modified).** Semantic triggers now take precedence regardless of size; "prefer SIMPLE" survives only for pure-size borderline with no semantic trigger |
| S5: no severity→verdict mapping; non-anchorable findings undefined | **Accepted.** P0/P1 → REQUEST CHANGES, P2/P3-only → COMMENT, APPROVE only when clean; non-anchorable findings go in the summary comment |
| S6: verification doesn't assert the full non-mutation invariant | **Declined by user** (same rationale as B2); verification keeps the no-pushed-commits check |

## 8. Related and future work (out of scope here)

Planned as separate workflows, each to get its own RFC:

- Docs update automation after PR merge (an `opencode-doc-management.reusable.yml` scheduled workflow already exists as a first step).
- A PR-comment workflow suggesting how the PR's changes could be simplified (`ce-simplify-code`, report-only).
- A PR autoheal workflow (max 3 attempts, then give up).
- A placeholder workflow for auto-updating/closing GitHub issues referenced by merged PRs (design not settled).
