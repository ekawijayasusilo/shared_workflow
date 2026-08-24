# RFC 0003: Replace the `ce-code-review` opencode reviewer with Alibaba open-code-review (ocr)

- **Status:** Draft — awaiting approval
- **Date:** 2026-08-20
- **Authors:** Eka Wijaya Susilo (requirements, decisions), Claude (research, drafting)
- **Reviewers:** Pending. Drafted from a live investigation (CI logs + source reads + end-to-end repros); an AI review pass will follow.

## 1. Background

[RFC 0001](0001-opencode-review-ce-code-review-triage.md) added an automatic,
report-only PR reviewer (`opencode-review.reusable.yml`). It triages each PR and,
for complex/risky changes, invokes the compound-engineering `ce-code-review`
skill in `mode:agent` through the opencode GitHub Action
(`anomalyco/opencode/github`, model `opencode-go/deepseek-v4-pro`, `variant: max`).

In practice the reviewer **never completes a real multi-agent review**. Every run
on a complex PR posts a summary that reads:

> "Review mode: COMPLEX-DEGRADED — the ce-code-review skill's reference files
> exist but its full multi-agent pipeline … cannot execute in this single-response
> CI context. The review was performed manually against the full diff."

The result is a single-model, best-effort review that can never return APPROVE —
i.e. the deep multi-agent review RFC 0001 was built for does not run. This RFC
diagnoses why and replaces the reviewer with a tool that actually completes.

## 2. What the user wants

1. A PR reviewer that **actually finishes** inside the CI time budget (not degraded).
2. Fast and token-efficient (the CE pipeline is neither, see §3).
3. Still posts **inline comments + a summary**, report-only, skipping draft/fork/bot PRs.
4. Provider-flexible (not locked to one gateway).
5. Replace **only** the review workflow; keep `ce-simplify-code` (RFC 0002) and the
   other family members unchanged.

## 3. Verified technical facts

Every fact below was verified this session from CI logs, opencode/CE/ocr source, and
end-to-end reproductions — not from documentation prose alone.

### 3.1 The degraded symptom is real and consistent
On the reference consumer PR, the opencode action ran only the `build` primary agent
for six loop steps using `git diff`/`read`, then self-declared `COMPLEX-DEGRADED`
without ever invoking the skill's multi-agent path. Clean exit, no error.

### 3.2 opencode *does* support subagents; the plugin doesn't register any
The `build` agent in `opencode github run` has the `task` tool available (a capability
probe dispatched opencode's built-in `general` subagent successfully — `PONG`). But the
compound-engineering opencode plugin (`.opencode/plugins/compound-engineering.js`) only
populates `config.command` + `config.skills.paths`; it never touches `config.agent`. So
CE registers **skills-as-commands, not opencode subagents**. CE's own reviewer dispatch
protocol (`references/dispatch-reviewers.md`) sidesteps this by spawning the **generic**
`general` subagent with a persona prompt injected — which works under opencode.

### 3.3 Root cause: sequential reviewers + pathological per-reviewer cost
`ce-code-review` dispatches its reviewer roster **strictly sequentially**:
> "Dispatch exactly one reviewer with background execution off, consume its returned
> compact JSON, then dispatch the next." (`dispatch-reviewers.md`)

An end-to-end repro (forced skill invocation, buggy fixture) showed the pipeline **did**
fan out — it selected 5–6 personas and dispatched `correctness-reviewer` as a `General
Agent`. But that **single** reviewer subagent ran **>23 minutes without finishing**,
tripping the job timeout. Six sequential reviewers at that cost is hours; the workflow's
25–30 min budget is exceeded on reviewer #1.

### 3.4 Not the gateway and not the model tier
Re-run against the **direct** DeepSeek API (`platform.deepseek.com`, OpenAI-compatible)
with the **faster** `deepseek-v4-flash` produced the **same** result: the single
`correctness-reviewer` ran >23 min and the job was cancelled at the 25-min timeout. So
the slowness is neither the `opencode-go` gateway nor the model tier — it is the
`ce-code-review` reviewer persona's per-invocation cost on deepseek models.

### 3.5 The platform is fine — `ce-simplify-code` proves it
On the identical model/gateway/runner, `ce-simplify-code` dispatched its **three**
reviewers **in parallel** (~35 s each) and finished end-to-end — apply + verification —
in **~2 minutes**. Same platform, opposite outcome. This isolates the fault to
`ce-code-review`'s sequential + heavy-per-reviewer design, not to opencode, the model,
or CI.

### 3.6 Cross-model adversarial is not the cause
`ce-code-review`'s cross-model adversarial pass shells out to a separate peer CLI
(`codex → claude → grok → composer`) which is absent on the CI runner, so it **silently
skips** by design. It is not what forces COMPLEX-DEGRADED.

### 3.7 What ocr is
Alibaba `open-code-review` (`ocr`, Go CLI, Apache-2.0, actively maintained) is a hybrid
**deterministic pipelines + LLM agent** reviewer. It bundles related files into review
units, each running as a subagent with isolated context, **concurrently** — a
divide-and-conquer design that stays fast on large changesets (self-reported ~1/9 tokens
and faster than baselines). It is OpenAI/Anthropic-compatible (any endpoint via
`llm_url`/`llm_auth_token`/`llm_model`), ships a native GitHub Action that self-handles
checkout/install/diff/review/comment, and posts inline comments + a **sticky** summary,
with **incremental** re-run dedupe.

### 3.8 ocr constraints and known unknowns
- ocr reviews **defects/security/performance/maintainability/test-coverage** — it is a
  reviewer, **not** a simplifier, and its rulesets explicitly de-prioritize
  simplification. So `ce-simplify-code` (RFC 0002) stays — the two occupy different lanes.
- ocr's agent needs a **tool-calling** model.
- `ocr_version` is intentionally **not pinned** (the wrapper installs the latest CLI); the
  Action wrapper itself is SHA-pinned and Renovate-tracked.
- **Runtime unknowns to confirm on first run:** (a) the opencode-zen `llm_url` shape
  (full `/chat/completions` path vs base — a wrong choice 404s), and (b) that the chosen
  `deepseek-v4-pro` exposes function-calling.

## 4. Options considered

### Option 1 — Replace the reviewer with ocr (**decided**)
A native, concurrent, provider-flexible reviewer that completes in CI. Keeps inline +
summary output. Different review philosophy from CE (defect-focused, no persona
adversarial), accepted as the cost of a reviewer that actually runs.

### Rejected options
- **Keep CE, accept COMPLEX-DEGRADED.** The degraded path is a single-model manual
  review that never returns APPROVE and delivers none of the multi-agent value RFC 0001
  intended. No reason to keep a permanently-degraded reviewer.
- **Tune the model / raise the timeout for CE.** Disproven: direct provider + flash tier
  gave the same >23 min per-reviewer timeout (§3.4). Raising the budget to hours is
  impractical and costly, and doesn't change the per-reviewer cost.
- **Fork CE to parallelize the personas.** CE serializes by design (deterministic queue
  for stable dedup); parallelizing means forking the skill, and even parallel wouldn't
  fix a >23 min single-reviewer cost.

## 5. Decided design

### 5.1 Central model config (already in place)
Model/provider config is centralized in a composite action
`.github/actions/model-config/` (`action.yml` reads `config.json` via `jq`). One edit
propagates to every consumer (callers track `@main`). It carries the opencode family's
`model`/`variant`/`plugin` and ocr's `llm_url`/`llm_model`/`llm_use_anthropic`. ocr's
provider is the opencode **zen** endpoint (`https://opencode.ai/zen/go/v1/chat/completions`),
model `deepseek-v4-pro`, `llm_use_anthropic: false`.

### 5.2 `ocr-review.reusable.yml` (thin wrapper)
The ocr action self-handles the heavy lifting, so the reusable workflow only adds guards
and central config:
- Job `if:` gate — **same-repo, non-draft, non-bot** PRs (fork PRs get no secret; bots
  never need review).
- A **Validate** step that fails fast when `OPENCODE_API_KEY` is empty.
- Loads the central `model-config@main`; the ocr action runs pinned to
  `alibaba/open-code-review@<v1.9.7 SHA>` with `incremental: true` + `sticky_summary: true`
  for clean re-runs on `synchronize`.
- Per-consumer `vars.OCR_LLM_URL` / `vars.OCR_LLM_MODEL` override the central defaults
  (fast provider failover from the repo Settings page, no file edit).
- `timeout-minutes: 30`; `permissions: contents: read, pull-requests: write`.

### 5.3 Caller stub `stubs/ocr-review.yml`
Family stub pattern: `on: pull_request [opened, synchronize, reopened, ready_for_review]`,
job `if: draft == false`, `uses:` the reusable `@main`, passes the optional `vars`
overrides, and forwards `OPENCODE_API_KEY`. No `permissions:` block — it relies on the
repo-level "Read and write permissions" setup, like the other stubs.

### 5.4 Removals
Delete the CE reviewer entirely — it is non-functional, so a "fallback" would be broken:
`.github/workflows/opencode-review.reusable.yml`, `stubs/opencode-review.yml`,
`prompts/opencode-review.md`. RFC 0001's status is marked **superseded by this RFC**.

### 5.5 Scope
Only the **review** workflow is replaced. The comment-triggered opencode assistant,
`ce-simplify-code` (RFC 0002), the scheduled doc-management workflow, and the Claude
assistant are unchanged. `ce-simplify-code` is explicitly retained — it is complementary
(refactor/simplification apply-and-suggest), a different job from ocr's defect review.

### 5.6 Auth
The endpoint is opencode zen, so the existing **`OPENCODE_API_KEY`** is ocr's bearer
token — consumers that already run any opencode workflow add **no new secret**; they
only swap the `opencode-review.yml` stub for `ocr-review.yml`.

## 6. Verification plan

After the `model-config` action + wired reusables land on `main` (push order: the
action must reach `main` with or before the reusables that reference it `@main`):

1. **Static** — the IDE "unresolved action `@main`" errors clear; the `jq`-based config
   action parses `config.json`.
2. **End-to-end test PR** — in a repo holding `OPENCODE_API_KEY`, open a PR adding a
   small buggy file (hardcoded secret + SQL injection + off-by-one expiry + `None`
   deref). Expect: ocr posts inline P0/P1 comments + a sticky summary and **finishes
   well under 30 min** (contrast: CE review timed out at 25 min on one reviewer).
3. **Re-run hygiene** — push a fix; the re-run **dedupes** overlapping inline comments
   (`incremental`) and **updates the summary in place** (`sticky_summary`) rather than
   stacking.
4. **Confirm the runtime unknowns (§3.8)** on that first run:
   - zen `llm_url` shape — if it 404s on a doubled path, trim to
     `https://opencode.ai/zen/go/v1`.
   - `deepseek-v4-pro` tool-calling — watch for function-call errors; fallback
     `deepseek-chat`.

## 7. Review resolution

Pending. This RFC is drafted from the session's investigation; an AI review pass will be
recorded here (Finding/Decision table) before the status moves to Approved.

## 8. Related and future work (out of scope here)

- **RFC 0001** (superseded by this RFC): the `ce-code-review` reviewer being replaced.
- Named GitHub App bot (short-lived write token, branded review author). Tracked in Todo.
- Reasoning-effort/variant for ocr via `llm_extra_body: {"reasoning_effort":"high|max"}`
  (deepseek-v4-pro accepts high/max on the zen endpoint) — deliberately omitted for now
  to keep ocr fast; tracked in Todo.
