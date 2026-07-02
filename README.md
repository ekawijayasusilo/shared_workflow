# shared_workflow

Centralized, reusable GitHub Actions workflows (`on: workflow_call`) shared across my repos.
The real logic lives here once; each consuming repo keeps only a tiny **caller stub**.

Reference: `ekawijayasusilo/shared_workflow`. This repo is **public**, so any repo can call
these workflows. Callers track `@main` (always latest).

## Reusable workflows

| File | Purpose |
| --- | --- |
| `.github/workflows/opencode.reusable.yml` | Comment-triggered opencode assistant. Makes changes / answers when a comment contains `/oc` or `/opencode`. Needs write perms. |
| `.github/workflows/opencode-review.reusable.yml` | Automatic PR reviewer. Runs opencode with a universal review prompt and posts inline review comments. |
| `.github/workflows/force-draft.reusable.yml` | Flips any PR opened as "ready" back to **draft**, making draft the effective default. Pairs with the reviewer's `draft == false` guard so review only runs once a PR is marked ready. |

The opencode action is **SHA-pinned** (`anomalyco/opencode/github@10c894b…` = `v1.17.13`);
Dependabot (`.github/dependabot.yml`) opens weekly bump PRs.

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
2. **Add the secret** (`GITHUB_TOKEN` is automatic — never set it):
   ```bash
   gh secret set OPENCODE_API_KEY --repo OWNER/REPO
   ```
3. Copy in the caller stub(s) above.

## Versioning

Callers track `@main`, so any merge to `main` reaches every consumer immediately. Keep `main`
green; the opencode action inside is SHA-pinned so behavior only changes on a deliberate edit
(or a merged Dependabot bump).
