# Per-repo TruffleHog secret scanning — design

**Date:** 2026-06-13
**Status:** Approved

## Goal

Scan every repository owned by the `dinoschristou` GitHub account for leaked
secrets using TruffleHog, run from a GitHub Actions workflow inside each repo
(no org-level or external infrastructure).

## Scope

- **In scope:** all non-archived repos owned by `dinoschristou`, excluding forks.
- **Out of scope:** archived repos (read-only, can't be fixed), forks, org-level
  aggregation, dashboards, automatic secret rotation, and auto-coverage of
  repos created in the future (re-run the rollout script to cover new repos).

## Components

### 1. The workflow file

Path in each repo: `.github/workflows/trufflehog.yml`. Identical across repos.

Uses the official `trufflesecurity/trufflehog` GitHub Action.

**Triggers:**
- `pull_request` — scan the PR's commit range (diff only). Fast feedback.
- `push` — scan the pushed diff.
- `schedule` (weekly cron) — scan the **full git history** via a complete
  checkout (`fetch-depth: 0`, filesystem scan, no base/head). Catches secrets
  already buried in history.

**Reporting / behaviour:**
- Verified-only reporting plus `--fail`: the run fails **only when TruffleHog
  verifies a secret is live** against its provider. This triggers GitHub's
  native failure email. Findings appear in the run logs / job summary.
- Uses the built-in `GITHUB_TOKEN`. No PAT required (a repo's own token can read
  that repo).

**Known nuance to resolve in implementation:** the TruffleHog action errors with
"BASE and HEAD are the same" on scheduled and first-push runs because there is
no diff. The scheduled (full-history) path must scan the working tree
(filesystem mode) rather than a commit diff. Exact action inputs
(`base`/`head`/`extra_args`/`path`) will be verified against the current
TruffleHog Action documentation when the workflow is written, since the action's
flags have changed across versions (e.g. `--only-verified` → `--results=verified`).

### 2. The rollout script

Path: `scripts/trufflehog-rollout.sh` (in this infra repo). Bash + `gh` + `git`.

**Behaviour:**
1. Enumerate targets: `gh repo list dinoschristou --no-archived --limit <high>`
   with JSON output, filtered to **exclude forks**.
2. For each target repo:
   - Shallow-clone to a temp dir.
   - Skip if `.github/workflows/trufflehog.yml` already exists on the default
     branch, or if an open PR adding it already exists (idempotency).
   - Create branch `ci/add-trufflehog`, add the workflow file, commit, push.
   - Open a PR with `gh pr create`.
3. Print a summary: PRs opened, repos skipped (and why).

The script is **idempotent** — safe to re-run; it only acts on repos that don't
already have the workflow or an open PR.

## Flow

```
trufflehog-rollout.sh
  → enumerates non-archived, non-fork repos
  → opens one PR per repo adding .github/workflows/trufflehog.yml
  → user reviews & merges each PR
  → workflow runs on every push/PR, plus weekly full-history scan
```

## Testing

- Validate the workflow YAML (syntax + action inputs) before rollout.
- Dry-run the rollout script against a single test repo first (open one PR,
  confirm the workflow runs green on a clean repo and red on a planted test
  secret) before scaling to all repos.
- Confirm idempotency by re-running the script and verifying it skips repos
  that already have the workflow or an open PR.
