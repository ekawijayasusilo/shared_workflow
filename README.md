# shared_workflow

Centralized, reusable GitHub Actions workflows (`on: workflow_call`) shared across my repos.
The real logic lives here once; each consuming repo keeps only a tiny **caller stub**.

Reference: `ekawijayasusilo/shared_workflow`. This repo is **public**, so any repo can call
these workflows. Callers track `@main` — whatever is on `main` here is live in every consuming
repo instantly.

## Reusable workflows

| File | Purpose |
| --- | --- |
| `.github/workflows/opencode.reusable.yml` | Comment-triggered opencode assistant. Makes changes / answers when a comment contains `/oc` or `/opencode`. Needs write perms. |
| `.github/workflows/opencode-review.reusable.yml` | Automatic PR reviewer. Runs opencode with a universal review prompt and posts inline review comments. |
| `.github/workflows/claude.reusable.yml` | Claude Code assistant. Runs `anthropics/claude-code-action` when an issue/PR/comment/review mentions `@claude`. |
| `.github/workflows/force-draft.reusable.yml` | Flips any PR opened as "ready" back to **draft**, making draft the effective default. Pairs with the reviewer's `draft == false` guard so review only runs once a PR is marked ready. |

Third-party actions are **SHA-pinned** (opencode `anomalyco/opencode/github@10c894b…` =
`v1.17.13`; `anthropics/claude-code-action@6c0083b…` = `v1.0.162`); Dependabot
(`.github/dependabot.yml`) opens weekly bump PRs.

## Caller stubs

Drop these into a consuming repo's `.github/workflows/`. The `on:` trigger and `if:` guards
**must** live in the stub — reusable workflows can't self-trigger. A `uses:` job may include
`if:` / `secrets:` but must NOT have `steps:` or `runs-on:`.

### `opencode.yml`
```yaml
name: opencode
on:
  issue_comment:
    types: [created]
  pull_request_review_comment:
    types: [created]
jobs:
  opencode:
    if: |
      contains(github.event.comment.body, ' /oc') ||
      startsWith(github.event.comment.body, '/oc') ||
      contains(github.event.comment.body, ' /opencode') ||
      startsWith(github.event.comment.body, '/opencode')
    uses: ekawijayasusilo/shared_workflow/.github/workflows/opencode.reusable.yml@main
    secrets:
      OPENCODE_API_KEY: ${{ secrets.OPENCODE_API_KEY }}
```

### `opencode-review.yml`
```yaml
name: opencode-review
on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]
jobs:
  review:
    if: github.event.pull_request.draft == false
    uses: ekawijayasusilo/shared_workflow/.github/workflows/opencode-review.reusable.yml@main
    secrets:
      OPENCODE_API_KEY: ${{ secrets.OPENCODE_API_KEY }}
```

### `claude.yml`
```yaml
name: Claude Code
on:
  issue_comment:
    types: [created]
  pull_request_review_comment:
    types: [created]
  issues:
    types: [opened, assigned]
  pull_request_review:
    types: [submitted]
jobs:
  claude:
    if: |
      (github.event_name == 'issue_comment' && contains(github.event.comment.body, '@claude')) ||
      (github.event_name == 'pull_request_review_comment' && contains(github.event.comment.body, '@claude')) ||
      (github.event_name == 'pull_request_review' && contains(github.event.review.body, '@claude')) ||
      (github.event_name == 'issues' && (contains(github.event.issue.body, '@claude') || contains(github.event.issue.title, '@claude')))
    uses: ekawijayasusilo/shared_workflow/.github/workflows/claude.reusable.yml@main
    secrets:
      CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

### `force-draft.yml` (optional — only in repos that want draft-by-default)
```yaml
name: force-draft
on:
  pull_request:
    types: [opened]
jobs:
  to-draft:
    if: github.event.pull_request.draft == false
    uses: ekawijayasusilo/shared_workflow/.github/workflows/force-draft.reusable.yml@main
```

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
