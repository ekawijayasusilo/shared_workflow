# RFC 0002: Suggestion-only code simplification for PRs with `ce-simplify-code`

- **Status:** Approved — implemented 2026-07-17
- **Date:** 2026-07-17
- **Authors:** Eka Wijaya Susilo (requirements, decisions), Claude (research, drafting)
- **Reviewers:** AI review pass completed 2026-07-17; all findings resolved in v2 (see Section 7)

## 1. Background

This repository (`ekawijayasusilo/shared_workflow`) hosts centralized reusable GitHub Actions workflows; consumer repos keep only tiny caller stubs that track `@main`.

[RFC 0001](0001-opencode-review-ce-code-review-triage.md) (approved, implemented) turned the PR review workflow into a triage-based reviewer: complex PRs get a deep multi-persona review via the compound-engineering `ce-code-review` skill in report-only `mode:agent`; simple PRs get a lean direct review. It hunts **defects**: bugs, regressions, security issues.

This RFC adds a second, independent per-PR workflow that hunts **excess**: code in the PR that works but is heavier than the problem requires. It runs the compound-engineering [`ce-simplify-code`](https://github.com/EveryInc/compound-engineering-plugin/blob/main/skills/ce-simplify-code/SKILL.md) skill — three reviewer lenses (Reuse / Quality / Efficiency) over the PR diff — and posts the results as **PR comments only**.

### Why `ce-code-review` alone is not enough

- Its always-on maintainability persona surfaces simplification only as confidence-gated side findings within a defect-focused pipeline; synthesis routinely suppresses advisory-grade output.
- It never performs the highest-yield simplification move: **cross-cutting reuse search** — checking whether the PR's new helper already exists elsewhere in the codebase (`ce-simplify-code`'s Reuse lens does exactly this).
- RFC 0001's SIMPLE review path is deliberately bug-only — simple PRs currently get zero simplification coverage.
- The yield is highest on AI-generated code, which industry-wide shows sharply increased duplication and halved refactoring since coding assistants went mainstream — and most PRs in the consumer repos are AI-authored.

The two workflows are complementary and run in parallel on the same PR events: review says "this is broken", simplify says "this could be less".

## 2. What the user wants

1. A new reusable workflow + caller stub, same architecture as the review workflow, that runs `ce-simplify-code` against a PR's changes.
2. **Suggestions only.** The workflow posts simplification recommendations as PR comments. It must never commit or push the simplifications itself.
3. A default prompt provided by this RFC (hardcoded in the reusable workflow, like the review workflow's).
4. Triggers identical to the review stub — `pull_request`: `opened`, `synchronize`, `reopened`, `ready_for_review` (user explicitly chose to include `synchronize`, accepting one run per push in exchange for fresh suggestions).
5. Noise controls (user-agreed): skip trivial diffs with a one-line comment; never invent findings; cap suggestions.

## 3. Verified technical facts

### 3.1 `ce-simplify-code` has no report-only mode

Source: [`skills/ce-simplify-code/SKILL.md`](https://github.com/EveryInc/compound-engineering-plugin/blob/main/skills/ce-simplify-code/SKILL.md) — the authoritative skill contract (per RFC 0001's lesson, the plugin's `docs/` pages can lag it).

- `argument-hint: "[blank to simplify current branch changes, or describe what to simplify]"` — the only arguments are scope; there is **no** `mode:agent` analog, no dry-run, no suggestions-only switch.
- The contract is **apply-then-verify**: three parallel reviewer agents find issues, the orchestrator applies the fixes in place, then runs typecheck + lint + scoped tests to confirm behavior is preserved. Each fix must pass a behavior-preservation check before being applied; the skill refuses to weaken assertions or skip tests to make checks pass.
- Consequence: unlike `ce-code-review` (RFC 0001), a "report-only" invocation cannot be requested from the skill. The report-only property must be produced **around** the skill, not inside it.

### 3.2 Local edits on the runner are structurally harmless

The workflow copies RFC 0001's posture: `contents: read` permission and `persist-credentials: false` on checkout. Pushing is impossible at the token level regardless of what the agent does. Local file edits live only in the runner workspace and are destroyed when the job ends. Therefore letting the skill apply its fixes **locally** does not violate the suggestions-only requirement — nothing can reach the repository except comments.

### 3.3 Verification when the toolchain is absent — the skill's own contract covers it

The opencode action installs no project dependencies, so the skill's typecheck/lint/test verification typically cannot run in CI. The skill contract itself defines the behavior for this case: *"If no test suite, lint, or typecheck is configured, state that explicitly in the summary; do not silently skip verification"* — i.e. proceed with disclosure, no revert. The fix-or-revert rule applies only when a check **runs and fails** because of a simplification.

The prompt therefore does not override the skill's verification semantics; it only maps the CI situation onto the contract's own branches: toolchain/dependencies not installed → treat as "no checks configured" (proceed + disclose); a runnable check failing due to a simplification → the skill's fix-or-revert stands. All posted suggestions carry an "unverified" note when checks could not run; anything the user click-applies is then validated by the PR's own CI.

### 3.4 The skill's preflight already classifies no-yield diffs

The skill runs its own preflight before dispatching reviewers: documentation-/Markdown-only, generated, vendored, dependency/lockfile, and purely mechanical (formatting, mass rename) scopes stop with a one-line note, and **mixed** diffs are narrowed to the code files and continue. This is stronger than a blanket workflow-side skip (which would discard the code half of a mixed diff), so the workflow prompt gates only on what the preflight deliberately does not: size/cost policy, which the contract assigns to the caller.

### 3.5 GitHub suggestion-block anchoring and limits

Inline review comments (and therefore ` ```suggestion ` blocks, which the PR author can apply with one click) can only attach to lines that appear in the PR's diff, and a suggestion replaces exactly the commented line range — which makes long or non-contiguous replacements fragile. Simplifications that touch lines *outside* the PR diff (e.g. deleting a now-unused export elsewhere in a file) cannot be inline suggestions and must be carried in the review body as regular diff blocks. Inline comments and a body can be submitted together as a single pull-request review (one notification) rather than as separate comments.

### 3.6 PR checkout does not materialize the skill's expected scope by default

`actions/checkout` on `pull_request` events checks out a **detached merge commit** at depth 1 — there is no branch, no base history, no merge base. The skill's default scope resolution ("current branch changes" against its base) has nothing to work with. The workflow must check out the PR head SHA with enough history to compute the merge base, and the prompt must state the scope explicitly.

### 3.7 Plugin loading and floating dependencies

Identical to RFC 0001 §3.3: the compound-engineering plugin loads via the `OPENCODE_CONFIG_CONTENT` env var (verified merge semantics — consumer repos' own `opencode.json` survives), unpinned by standing user decision. Additionally, the SHA-pinned action itself installs the **latest opencode runtime** at run time — so there are two deliberately floating dependencies (plugin and runtime) even though the action reference is immutable. Fork/bot PRs run without secrets and must be skipped by the same job guard (RFC 0001 §3.5).

## 4. Options considered

### Option 1 — Local-apply, suggest-only posting (**decided**)

Invoke the skill as designed and let it edit the local checkout; then the agent reads the resulting `git diff` and posts it back as one PR review — inline ` ```suggestion ` blocks where a change anchors cleanly to PR-changed lines, diff blocks in the review body otherwise.

**Pros:** uses the skill's real machinery (parallel three-lens review, behavior-preservation judgment per fix, structure-pin honoring); suggestions are concrete code, one-click applicable; report-only is structurally guaranteed (§3.2) rather than promised; no fight with the skill's contract.

**Cons:** verification is usually degraded in CI (§3.3) — suggestions ship unverified with disclosure; a run costs three subagent dispatches even when little is found (mitigated by the size gate and the skill's own preflight).

### Option 2 — Emulate the three lenses in the prompt, never invoke the skill (rejected)

A prompt replicating Reuse/Quality/Efficiency review report-only. Cleaner constraint story, but discards the skill's actual machinery (structured lens prompts, per-fix behavior-preservation gate, scope resolution) and produces suggestions that were never even locally applied — strictly lower fidelity for the same token cost.

### Option 3 — Invoke the skill but prompt-forbid all edits (rejected)

"Run `ce-simplify-code` but do not change any files" contradicts the skill's own apply-then-verify instructions mid-invocation. The agent receives two conflicting authorities; outcome is unpredictable (fixes applied anyway, or a half-run). Never instruct against an invoked skill's contract.

### Option 4 — Fold simplification into the review workflow prompt (rejected)

One workflow, one comment thread. Rejected: different concern with a different cadence and different failure tolerance; consumer repos should be able to adopt review without simplify (or vice versa); separate workflows run in parallel instead of serially inflating one job's wall-clock; and RFC 0001's prompt is already at healthy complexity.

## 5. Decided design

### 5.1 New files (implementation phase, after this RFC is approved)

- **`.github/workflows/opencode-simplify.reusable.yml`** — mirrors `opencode-review.reusable.yml` with these deltas:
  - Same job guard (non-draft, same-repo, non-bot author), same permissions (`contents: read`, `pull-requests: write`, `issues: write`; no `id-token`), same unpinned-plugin `OPENCODE_CONFIG_CONTENT`, `model: opencode-go/deepseek-v4-pro`, `variant: max`, same SHA-pinned action version the review workflow uses at implementation time. Both the plugin and the opencode runtime float by standing decision (§3.7).
  - **Checkout** (§3.6): `ref: ${{ github.event.pull_request.head.sha }}`, `fetch-depth: 0`, `persist-credentials: false` — PR head, full history, no credentials.
  - **Concurrency**: one run per PR at a time, newest wins —

    ```yaml
    concurrency:
      group: opencode-simplify-${{ github.event.pull_request.number }}
      cancel-in-progress: true
    ```

- **`stubs/opencode-simplify.yml`** — caller stub: `pull_request` on `opened`/`synchronize`/`reopened`/`ready_for_review`, `if: github.event.pull_request.draft == false`, passes `OPENCODE_API_KEY`.
- README rows for both.

### 5.2 Default prompt

````text
You are producing code-simplification suggestions for a pull request. Your
final deliverable is PR comments only. You must never commit, push, or create
branches, and never create, close, or edit issues or the PR itself. Local
file edits inside the runner workspace are expected and allowed — they are
discarded when the runner exits and must never leave it.

Step 0 — Dedup (re-runs). List the PR's existing comments and review
comments. Comments containing the marker "<!-- opencode-simplify" are from
previous runs of this workflow; ignore all other comments for dedup purposes.
Read those marked comments and do not re-post any suggestion that is still
valid against the current diff; only suggest for code that changed since.

Step 1 — Size gate. If the PR changes fewer than roughly 10 lines, post one
short comment: "No simplification opportunities worth suggesting on this
diff." and stop. Do not pre-filter by change kind (docs-only, generated
files, dependency bumps) — the ce-simplify-code skill's own preflight
classifies those and narrows mixed diffs better than a blanket skip. If its
preflight reports nothing to simplify, post the same one-line comment.

Step 2 — Simplify. Invoke the ce-simplify-code skill scoped to this PR's
changes: the diff from the merge base with the PR's base branch to HEAD.
The skill will edit files in the local checkout; that is expected.
Verification mapping: if typecheck/lint/tests cannot run here because the
toolchain or dependencies are not installed, treat that as the skill
contract's "no checks configured" case — proceed and disclose it in the
summary. If a check does run and fails because of a simplification, follow
the skill's contract: fix or revert that specific change.

Step 3 — Post suggestions. Inspect the local diff the skill produced
(git diff). First re-check the PR head: if new commits were pushed since
checkout, stop without posting — the next run covers them.
Post everything as ONE pull-request review with event COMMENT, containing at
most 10 suggestions in total:
- A change qualifies for an inline ```suggestion block only when it is a
  contiguous replacement of at most 10 lines that all appear among the PR
  diff's changed lines. Give each one sentence on why, tagged by dimension
  (reuse / quality / efficiency).
- Everything else — deletions elsewhere, non-contiguous edits, rewrites
  longer than 10 lines, changes outside the PR's changed lines — goes in
  the review body as regular diff blocks, still counted within the 10.
- If there are more than 10 candidates, keep the 10 highest-impact and
  state only the count of omitted ones.
The review body also contains: suggestions grouped by dimension, what was
already good as-is, and — when checks could not run — a note that the
suggestions are unverified and should be validated by the PR's own CI after
applying. End the review body, and every comment this workflow posts, with
the marker line:
<!-- opencode-simplify run:<PR head SHA> -->
If the skill produced no changes, post only the one-line "no opportunities"
comment (with the marker). Do not invent suggestions to justify the run.
````

### 5.3 Noise-control summary

| Control | Mechanism |
| --- | --- |
| Trivial diffs | Workflow size gate (<10 changed lines) — one-line comment, no skill cost |
| Docs-only/generated/bump diffs | Skill's own preflight classifies and skips (narrows mixed diffs); one-line comment |
| Nothing found | Same one-line comment; inventing findings explicitly forbidden |
| Suggestion flood | Hard cap: 10 suggestions **total** (inline + body combined); overflow reported as a count only |
| Notification spam | Everything posted as one COMMENT review, not separate comments |
| `synchronize` re-runs | Concurrency group cancels superseded runs; head re-check before posting; marker-scoped dedup (`<!-- opencode-simplify run:<sha> -->`) never re-posts still-valid suggestions |

## 6. Verification plan

After implementation merges to `main`, in a consumer repo:

1. **Findings PR** — deliberately simplifiable code (a helper duplicating an existing utility, a dead export, a nested ternary, two sequential awaits that could be parallel). Expect: plugin install + `ce-simplify-code` invocation in logs; one COMMENT review with inline ` ```suggestion ` blocks on PR-changed lines, dimension tags, unverified-checks note, marker line; **no commits pushed**.
2. **Clean PR** — substantive but already-simple code. Expect: the one-line "no opportunities" comment with marker; no invented findings.
3. **Overflow PR** — more than 10 candidate findings (e.g. many copy-pasted helpers). Expect: exactly 10 suggestions, omitted count stated.
4. **Multi-line routing** — one small (≤10-line) multi-line simplification and one whole-function rewrite. Expect: the former inline as a suggestion block, the latter in the review body as a diff block.
5. **Rapid pushes** — two pushes in quick succession. Expect: first run cancelled by the concurrency group (or aborted at the head re-check); only the newest run posts.
6. **Rerun dedup** — push a commit touching one file of an already-reviewed PR. Expect: no re-posted suggestions for unchanged code (dedup via marker-bearing comments); new suggestions only for the changed file.
7. **Docs-only PR** — expect the one-line comment via the skill's preflight; reviewers never dispatched (visible in logs).

## 7. Review resolution (2026-07-17)

An external AI review of v1 produced 1 BLOCKER, 7 SHOULD-FIX, and 1 NIT. Resolution:

| Finding | Decision |
| --- | --- |
| B1: "proceed unverified" contradicts the skill's verification contract | **Accepted (reframed).** The contract itself defines the checks-unavailable branch ("no checks configured → state explicitly, don't skip silently"); prompt now maps CI conditions onto the contract's own branches instead of overriding them (§3.3, prompt Step 2). Reviewer's alternative — post no suggestions when checks cannot run — **rejected**: it would disable the workflow in every CI run, and the contract does not require it |
| S1: PR checkout doesn't materialize the skill's scope | **Accepted.** Checkout PR head SHA + `fetch-depth: 0`; prompt states scope = merge-base..HEAD (§3.6, §5.1) |
| S2: overlapping `synchronize` runs post stale suggestions | **Accepted.** Per-PR concurrency group with `cancel-in-progress: true` + head re-check before posting (§5.1, prompt Step 3) |
| S3: dedup lacks stable identity | **Accepted (simplified).** Hidden marker `<!-- opencode-simplify run:<sha> -->` on every posted comment; dedup considers only marker-bearing comments. Full path/range/text fingerprinting **rejected** as overkill — pushed code shifts line ranges and defeats exact matching anyway |
| S4: workflow screening duplicates the skill's preflight | **Accepted.** Step 1 now gates on size only (the one policy the preflight assigns to callers); change-kind classification delegated to the skill's preflight, which also narrows mixed diffs (§3.4) |
| S5: single-line anchors can't carry arbitrary multi-line replacements | **Accepted (core).** Inline suggestion blocks restricted to contiguous ≤10-line replacements fully within PR-changed lines; deletions/non-contiguous/larger → review body. Prescribing exact API parameters (`commit_id`, `start_line`, …) **rejected** — the agent posts via `gh` and over-specification invites brittleness |
| S6: 10-inline cap doesn't bound total noise | **Accepted.** Cap is now 10 suggestions total; overflow reported as a count only; everything submitted as one COMMENT review |
| S7: verification plan missed declared paths | **Accepted.** Fixtures added: clean PR, overflow PR, multi-line routing, rapid pushes, rerun dedup (§6) |
| N1: action SHA doesn't pin the opencode runtime | **Accepted.** Documented as the second deliberately floating dependency (§3.7) |

## 8. Related and future work (out of scope here)

- RFC 0001 (approved, implemented): triage-based PR review — the sibling workflow this one complements.
- Scheduled docs maintenance workflow already exists (`opencode-doc-management.reusable.yml`).
- Still planned, each with its own RFC: PR autoheal (max 3 attempts), and a placeholder for auto-updating/closing GitHub issues referenced by merged PRs.
