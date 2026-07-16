# shared_workflow

Centralized, reusable GitHub Actions workflows (`on: workflow_call`) shared across my repos.
The real logic lives here once; each consuming repo keeps only a tiny **caller stub**.

Reference: Callers track `@main` — whatever is on `main` here is live in every consuming repo instantly.

## Reusable workflows

| File | Purpose |
| --- | --- |
| `.github/workflows/opencode.reusable.yml` | Comment-triggered opencode assistant. Makes changes / answers when a comment contains `/oc` or `/opencode`. Needs write perms. |
| `.github/workflows/opencode-review.reusable.yml` | Automatic PR reviewer. Runs opencode with a universal review prompt and posts inline review comments. |
| `.github/workflows/opencode-doc-management.reusable.yml` | Scheduled docs maintainer. Runs opencode with the [compound-engineering plugin](https://github.com/EveryInc/compound-engineering-plugin) loaded (latest, via `OPENCODE_CONFIG_CONTENT`), syncs stale docs with recent code changes, and auto-opens a PR with the edits. Optional `prompt` input overrides the default task. |
| `.github/workflows/claude.reusable.yml` | Claude Code assistant. Runs `anthropics/claude-code-action` when an issue/PR/comment/review mentions `@claude`. |
| `.github/workflows/force-draft.reusable.yml` | Flips any PR opened as "ready" back to **draft**, making draft the effective default. Pairs with the reviewer's `draft == false` guard so review only runs once a PR is marked ready. |

Third-party actions are **SHA-pinned** (opencode `anomalyco/opencode/github@10c894b…` =
`v1.17.13`; `anthropics/claude-code-action@6c0083b…` = `v1.0.162`); Dependabot
(`.github/dependabot.yml`) opens weekly bump PRs.

## Caller stubs

Ready-made stubs live in [`stubs/`](stubs/). Copy the one(s) you want into a consuming repo's
`.github/workflows/` (same filename). Each already targets `@main` and passes the right secret.

| Copy | calls | secret |
| --- | --- | --- |
| [`stubs/opencode.yml`](stubs/opencode.yml) | `opencode.reusable.yml` | `OPENCODE_API_KEY` |
| [`stubs/opencode-review.yml`](stubs/opencode-review.yml) | `opencode-review.reusable.yml` | `OPENCODE_API_KEY` |
| [`stubs/opencode-doc-management.yml`](stubs/opencode-doc-management.yml) | `opencode-doc-management.reusable.yml` | `OPENCODE_API_KEY` |
| [`stubs/claude.yml`](stubs/claude.yml) | `claude.reusable.yml` | `CLAUDE_CODE_OAUTH_TOKEN` |
| [`stubs/force-draft.yml`](stubs/force-draft.yml) _(optional — draft-by-default)_ | `force-draft.reusable.yml` | — |

The `on:` trigger and `if:` guards live in the stub — reusable workflows can't self-trigger. A
`uses:` job may include `if:` / `secrets:` but must NOT have `steps:` or `runs-on:`. (These
files sit in `stubs/`, not `.github/workflows/`, so they don't run here.)

## Per-repo setup (manual, once per consuming repo)

1. **Workflow permissions** → Settings → Actions → General → **Read and write permissions**.
   This is a hard cap on what the workflow's `permissions:` block can request; the assistant
   needs `contents: write` to push commits. CLI equivalent:
   ```bash
   gh api -X PUT repos/OWNER/REPO/actions/permissions/workflow \
     -F default_workflow_permissions=write
   ```
2. **Add the secrets** (`GITHUB_TOKEN` is automatic — never set it). Add only the ones whose
   stubs you copied:
   ```bash
   gh secret set OPENCODE_API_KEY --repo OWNER/REPO        # opencode + opencode-review
   gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo OWNER/REPO # claude
   ```
3. Copy in the caller stub(s) above.

## Versioning

Callers track `@main`, so any merge to `main` is live in every consumer immediately. Keep
`main` green (protect it with required PR review once ready). The third-party actions inside
are SHA-pinned, so behavior only changes on a deliberate edit or a merged Dependabot bump.
