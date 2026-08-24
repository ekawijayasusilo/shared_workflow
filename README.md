# shared_workflow

Centralized, reusable GitHub Actions workflows (`on: workflow_call`) and modular Renovate
presets shared across my repos. The real logic lives here once; each consuming repo keeps
only a tiny caller stub and an opt-in `renovate.json`.

Consumers pin exact `vX.Y.Z` releases. There is deliberately no floating major tag. This
repository completed its release bootstrap with `v1.1.0`; its ready-made caller stubs use
exact tags and are maintained by Renovate.

## Reusable workflows

| File | Purpose |
| --- | --- |
| `.github/workflows/opencode.reusable.yml` | Comment-triggered opencode assistant. Makes changes / answers when a comment contains `/oc` or `/opencode`. Needs write perms. |
| `.github/workflows/ocr-review.reusable.yml` | Automatic PR reviewer (report-only). Runs [Alibaba open-code-review](https://github.com/alibaba/open-code-review) (`ocr`) — a hybrid deterministic + agent reviewer that bundles files into **concurrent** subagents; posts inline defect/security/perf comments + a sticky summary, with incremental re-run dedupe. Skips draft, fork, and bot PRs. Replaces the former `ce-code-review` reviewer (RFC 0001). See [RFC 0003](docs/rfc/0003-opencode-ocr-review-replacement.md). |
| `.github/workflows/opencode-simplify.reusable.yml` | PR simplification suggester. Runs the compound-engineering `ce-simplify-code` skill on the PR diff (local-apply only — nothing is pushed) and posts the result as one COMMENT review with one-click ` ```suggestion ` blocks, max 10 total. Skips draft, fork, and bot PRs. See [RFC 0002](docs/rfc/0002-opencode-simplify-suggestions.md). |
| `.github/workflows/opencode-doc-management.reusable.yml` | Scheduled docs maintainer. Runs opencode with the [compound-engineering plugin](https://github.com/EveryInc/compound-engineering-plugin) loaded (latest, via `OPENCODE_CONFIG_CONTENT`), syncs stale docs with recent code changes, and auto-opens a PR with the edits. Optional `prompt` input overrides the default task. |
| `.github/workflows/claude.reusable.yml` | Claude Code assistant. Runs `anthropics/claude-code-action` when an issue/PR/comment/review mentions `@claude`. |
| `.github/workflows/flutter-ci.reusable.yml` | Owned Flutter CI with formatting, analysis, tests, per-package Codecov coverage, non-blocking Test Analytics, and a safe `build` fan-in check. |
| `.github/workflows/semantic-pull-request.reusable.yml` | Thin, exact-revision forwarder to Very Good Workflows' semantic pull-request workflow. |
| `.github/workflows/pub-license-check.reusable.yml` | Thin, exact-revision forwarder to Very Good Workflows' pub license checker. |

Reusable-workflow assets are resolved from the exact revision that defines the invoked job.
For example, the simplify prompt is fetched using the reusable workflow's repository and
commit SHA, and the model-config composite action is checked out at that same SHA. A consumer
pinned to a release therefore cannot accidentally receive prompt or model behavior from
`main`.

Direct third-party action references in owned workflows are SHA-pinned. The two thin VGV
forwarders pin the complete upstream reusable workflow to an immutable commit, but inherit
the third-party references used inside that upstream workflow. Renovate is the repository's
sole dependency-update service.

## Caller stubs

Ready-made stubs live in [`stubs/`](stubs/). Copy the one(s) you want into a consuming repo's
`.github/workflows/` using the same filename. They pin the current exact release; Renovate can
then update the workflow and preset references together in one dependency PR.

| Copy | calls | secret |
| --- | --- | --- |
| [`stubs/opencode.yml`](stubs/opencode.yml) | `opencode.reusable.yml` | `OPENCODE_API_KEY` |
| [`stubs/ocr-review.yml`](stubs/ocr-review.yml) | `ocr-review.reusable.yml` | `OPENCODE_API_KEY` |
| [`stubs/opencode-simplify.yml`](stubs/opencode-simplify.yml) | `opencode-simplify.reusable.yml` | `OPENCODE_API_KEY` |
| [`stubs/claude.yml`](stubs/claude.yml) | `claude.reusable.yml` | `CLAUDE_CODE_OAUTH_TOKEN` |
| [`stubs/flutter-ci.yml`](stubs/flutter-ci.yml) | `flutter-ci.reusable.yml` | `CODECOV_TOKEN` (optional for some public repositories) |
| [`stubs/pub-license-check.yml`](stubs/pub-license-check.yml) | `pub-license-check.reusable.yml` | None |
| [`stubs/semantic-pull-request.yml`](stubs/semantic-pull-request.yml) | `semantic-pull-request.reusable.yml` | None |

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
   gh secret set OPENCODE_API_KEY --repo OWNER/REPO        # opencode + ocr-review + opencode-simplify
   gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo OWNER/REPO # claude
   gh secret set CODECOV_TOKEN --repo OWNER/REPO           # flutter-ci
   ```
3. Copy in the caller stub(s) above.

## Versioning

Release Please uses the `simple` strategy: `version.txt` is the version source and release PRs
generate `CHANGELOG.md`, exact `vX.Y.Z` tags, and GitHub Releases. The first exact release is
`v1.1.0`. Release automation uses the Renovate GitHub App token so release PR checks and
tag-triggered workflows are not suppressed.

Repository setup requires:

- Variable `RENOVATE_APP_ID` containing the GitHub App ID.
- Secret `RENOVATE_APP_PRIVATE_KEY` containing its private key.
- App permissions for Contents, Pull requests, Issues, and Workflows as used by the release
  and Renovate workflows.

Do not create or update a floating `v1` tag. Consumers move to a new exact version through a
normal dependency update PR.

## Renovate presets

Presets live in [`renovate/`](renovate/) and are composed at one exact release tag. A Flutter
repository can opt in with:

```json
{
  "extends": [
    "github>ekawijayasusilo/shared_workflow//renovate/default#vX.Y.Z",
    "github>ekawijayasusilo/shared_workflow//renovate/flutter#vX.Y.Z"
  ]
}
```

An Android-only repository composes `default` and `gradle` instead, without Dart or Flutter
rules. The central runner discovers repositories visible to the App, but processes only those
that explicitly commit a Renovate configuration. `renovate/allowlist.json` is exclusively the
named pub-package automerge whitelist; grouped package families must not be added to it.

The runner executes daily at 03:17 Asia/Jakarta. The seven-day release-age policy controls
dependency stability, while vulnerability alerts bypass that delay.

## Flutter workflow attribution

`.github/workflows/flutter-ci.reusable.yml` is derived from
[VeryGoodOpenSource/very_good_workflows](https://github.com/VeryGoodOpenSource/very_good_workflows)
commit `f053008378cc15a643a9050e67b0417bc548e7e8`, licensed under the MIT License,
Copyright (c) 2021 Very Good Ventures.

Codecov is the coverage authority. The local minimum defaults to zero, coverage uploads use
one flag per package, and Test Analytics is best-effort. Consumer branch protection should
require both the workflow's `build` check and the configured Codecov project/patch statuses.
Set `CODECOV_TOKEN` for every private repository. Public repositories also need it unless the
Codecov account allows tokenless uploads for public repositories.

The Flutter CI workflow also centralizes Dart Code Linter enforcement for pub workspaces:

| Input | Type | Default | Purpose |
| --- | --- | --- | --- |
| `run_dart_code_linter` | boolean | `true` | Runs DCL analysis and unused code/file checks in the root package and every `workspace:` member with a `lib/` directory. The step skips cleanly when `dart_code_linter` is not resolved from the root package. |
| `l10n_class_pattern` | string | `""` | When non-empty, runs the root package's unused-localization check with this generated localization class pattern. Unused-localization findings are non-fatal because Flutter's generated localization API contains permanent unused fixtures. |

Add `dart_code_linter` to the root package's `dev_dependencies` to enable the gate for the
whole workspace. Analysis warnings, style findings, performance findings, and metric threshold
violations fail CI; unused code and unused files keep DCL's fatal default.

## Todo

[x] Versioning via Release Please and GitHub Releases.
[x] Migrate dependency updates from Dependabot to Renovate.
[ ] Create a custom Renovate rule to update LLM model versions from the OpenCode model registry.
[ ] Create Github app for this repo (CodeDayCare) to enable named bot to post the code review & for security purposes (limited time repo write token instead of manual Github PAT setup on consumer repo secret).
[ ] Reorganize proiject structure and abstract workflow & name better to decouple from real implementation (opencode, ocr).
[ ] Support reasoning-effort/variant for ocr. Central config wires `variant` for the opencode workflows but ocr ignores it — ocr uses the model's default. To add: pass `llm_extra_body: {"reasoning_effort":"high|max"}` (deepseek-v4-pro accepts high/max on the opencode zen endpoint).

## Future Workflow

[ ] Autoheal workflow. Triggered upon linter/formatter/test job failure. Try to automatically fix it
[ ] Auto Documentation workflow. Daily or upon release or upon merge to main, analyze the changes made, decide whether any claude.md or readme or documentation or test case scenarios need to be updated.
[ ] Auto Issue Drafter workflow. Based on PR issue comment or PR body, if mentioning issue to be tracked in Github issue, then draft and triage the issue
[ ] Auto Security Issue handler. Upon issue being raised by SAST / SCA in Github security, try check and resolve the issue, opening PR that update the dependency / resolve the issue.
