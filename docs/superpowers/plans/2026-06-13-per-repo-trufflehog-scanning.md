# Per-repo TruffleHog Secret Scanning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a TruffleHog secret-scanning GitHub Actions workflow to every non-archived, non-fork repo owned by `dinoschristou`, rolled out via one PR per repo.

**Architecture:** A single canonical workflow file (`.github/workflows/trufflehog.yml`) is added to each repo. It scans pushed/PR diffs for fast feedback and runs a weekly full-history scan, failing the run only on verified-live secrets. An idempotent bash rollout script enumerates target repos via `gh` and opens a PR per repo adding the workflow.

**Tech Stack:** GitHub Actions, `trufflesecurity/trufflehog` action, `gh` CLI, `git`, bash, `jq`.

---

## File Structure

- `scripts/trufflehog/trufflehog.yml` — canonical workflow template (source of truth in this repo). Copied verbatim into each target repo at `.github/workflows/trufflehog.yml`.
- `scripts/trufflehog/rollout.sh` — idempotent rollout script (enumerate → clone → branch → commit → PR).
- `scripts/trufflehog/README.md` — short usage notes (how to run rollout, how to re-run for new repos, testing notes).

All three live in this infra repo. The workflow file is *deployed* into other repos; the script and README stay here.

---

## Task 1: Create the canonical workflow file

**Files:**
- Create: `scripts/trufflehog/trufflehog.yml`

- [ ] **Step 1: Write the workflow file**

Create `scripts/trufflehog/trufflehog.yml` with exactly this content:

```yaml
name: TruffleHog Secret Scan

on:
  push:
  pull_request:
  schedule:
    # Weekly full-history scan, Mondays 07:00 UTC
    - cron: "0 7 * * 1"
  workflow_dispatch:

permissions:
  contents: read

jobs:
  scan:
    name: TruffleHog
    runs-on: ubuntu-latest
    steps:
      - name: Checkout (full history)
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      # Push / PR: scan only the new commits (action auto-detects base/head).
      - name: TruffleHog diff scan
        if: github.event_name == 'push' || github.event_name == 'pull_request'
        uses: trufflesecurity/trufflehog@main
        with:
          # The action injects --fail itself; do not add it here (it errors if repeated).
          extra_args: --results=verified

      # Schedule / manual: scan the entire git history (base="" disables diff).
      - name: TruffleHog full-history scan
        if: github.event_name == 'schedule' || github.event_name == 'workflow_dispatch'
        uses: trufflesecurity/trufflehog@main
        with:
          base: ""
          head: ${{ github.ref_name }}
          # The action injects --fail itself; do not add it here (it errors if repeated).
          extra_args: --results=verified
```

Notes baked into this file:
- `--results=verified` → reports only secrets TruffleHog confirms are live.
- The run exits non-zero (red) when such a secret is found, which triggers GitHub's native failure email. Recent action versions also write findings to the job summary. NOTE: the action's entrypoint already passes `--fail`, so adding `--fail` to `extra_args` causes `flag 'fail' cannot be repeated` — do not include it.
- `fetch-depth: 0` is required so the scheduled full-history scan sees all commits.

- [ ] **Step 2: Validate the YAML syntax**

Run:
```bash
python3 -c "import yaml,sys; yaml.safe_load(open('scripts/trufflehog/trufflehog.yml')); print('valid yaml')"
```
Expected: `valid yaml`

- [ ] **Step 3: Commit**

```bash
git add scripts/trufflehog/trufflehog.yml
git commit -m "feat(trufflehog): add canonical secret-scan workflow template"
```

---

## Task 2: Write the rollout script

**Files:**
- Create: `scripts/trufflehog/rollout.sh`

- [ ] **Step 1: Write the script**

Create `scripts/trufflehog/rollout.sh` with exactly this content:

```bash
#!/usr/bin/env bash
#
# Roll out the TruffleHog scan workflow to all non-archived, non-fork repos
# owned by the GitHub user. Opens one PR per repo. Idempotent: skips repos that
# already have the workflow or an open rollout PR.
#
# Usage:
#   ./rollout.sh [--dry-run] [--owner OWNER] [--limit N] [--repo OWNER/NAME]
#
#   --dry-run        Print what would happen; make no changes.
#   --owner OWNER    GitHub owner to scan (default: dinoschristou).
#   --limit N        Max repos to enumerate (default: 1000).
#   --repo O/N       Act on a single repo only (for testing). Repeatable.
#
set -euo pipefail

OWNER="dinoschristou"
LIMIT=1000
DRY_RUN=false
BRANCH="ci/add-trufflehog"
WORKFLOW_PATH=".github/workflows/trufflehog.yml"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/trufflehog.yml"
SINGLE_REPOS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --owner)   OWNER="$2"; shift 2 ;;
    --limit)   LIMIT="$2"; shift 2 ;;
    --repo)    SINGLE_REPOS+=("$2"); shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ ! -f "$TEMPLATE" ]]; then
  echo "Template not found: $TEMPLATE" >&2
  exit 1
fi

# Build the list of "owner/name<TAB>defaultBranch" target lines.
if [[ ${#SINGLE_REPOS[@]} -gt 0 ]]; then
  TARGETS=""
  for r in "${SINGLE_REPOS[@]}"; do
    branch=$(gh repo view "$r" --json defaultBranchRef --jq '.defaultBranchRef.name')
    TARGETS+="${r}	${branch}"$'\n'
  done
else
  # --source excludes forks, --no-archived excludes archived. Skip empty repos.
  TARGETS=$(gh repo list "$OWNER" --source --no-archived --limit "$LIMIT" \
    --json nameWithOwner,defaultBranchRef,isEmpty \
    --jq '.[] | select(.isEmpty == false) | "\(.nameWithOwner)\t\(.defaultBranchRef.name)"')
fi

opened=0; skipped=0
while IFS=$'\t' read -r repo default_branch; do
  [[ -z "$repo" ]] && continue

  # Skip if workflow already exists on the default branch.
  if gh api "repos/${repo}/contents/${WORKFLOW_PATH}" --jq '.sha' >/dev/null 2>&1; then
    echo "SKIP  ${repo} (workflow already present)"
    skipped=$((skipped+1)); continue
  fi

  # Skip if an open rollout PR already exists.
  existing_pr=$(gh pr list -R "$repo" --head "$BRANCH" --state open --json number --jq 'length')
  if [[ "$existing_pr" != "0" ]]; then
    echo "SKIP  ${repo} (open PR already exists)"
    skipped=$((skipped+1)); continue
  fi

  if $DRY_RUN; then
    echo "PLAN  ${repo} -> would open PR adding ${WORKFLOW_PATH} (base: ${default_branch})"
    opened=$((opened+1)); continue
  fi

  tmp=$(mktemp -d)
  git clone --depth 1 "https://github.com/${repo}.git" "$tmp" >/dev/null 2>&1
  (
    cd "$tmp"
    git checkout -b "$BRANCH" >/dev/null 2>&1
    mkdir -p "$(dirname "$WORKFLOW_PATH")"
    cp "$TEMPLATE" "$WORKFLOW_PATH"
    git add "$WORKFLOW_PATH"
    git commit -m "ci: add TruffleHog secret-scan workflow" >/dev/null
    git push -u origin "$BRANCH" >/dev/null 2>&1
    gh pr create -R "$repo" \
      --base "$default_branch" --head "$BRANCH" \
      --title "ci: add TruffleHog secret scanning" \
      --body "Adds a scheduled + push/PR TruffleHog secret scan. Fails only on verified-live secrets. See infra repo scripts/trufflehog/." >/dev/null
  )
  rm -rf "$tmp"
  echo "PR    ${repo}"
  opened=$((opened+1))
done <<< "$TARGETS"

echo "---"
echo "Done. opened/planned=${opened} skipped=${skipped}"
```

- [ ] **Step 2: Make it executable and lint it**

Run:
```bash
chmod +x scripts/trufflehog/rollout.sh
bash -n scripts/trufflehog/rollout.sh && echo "syntax ok"
```
Expected: `syntax ok`

If `shellcheck` is installed, also run `shellcheck scripts/trufflehog/rollout.sh` and address any errors (warnings optional).

- [ ] **Step 3: Commit**

```bash
git add scripts/trufflehog/rollout.sh
git commit -m "feat(trufflehog): add idempotent per-repo rollout script"
```

---

## Task 3: Verify enumeration and idempotency with a dry run

**Files:** none (verification only)

- [ ] **Step 1: Dry-run against all repos**

Run:
```bash
./scripts/trufflehog/rollout.sh --dry-run
```
Expected: a list of `PLAN <owner>/<repo> -> would open PR ...` lines for repos without the workflow, `SKIP ...` lines for any that already have it, and a final `Done. opened/planned=N skipped=M` summary. No PRs are created. Confirm the listed repos are the ones you expect (no forks, no archived repos).

- [ ] **Step 2: Sanity-check the target list independently**

Run:
```bash
gh repo list dinoschristou --source --no-archived --limit 1000 \
  --json nameWithOwner,isFork,isArchived --jq '.[] | "\(.nameWithOwner) fork=\(.isFork) archived=\(.isArchived)"'
```
Expected: every line shows `fork=false archived=false`. This confirms the `--source --no-archived` filters behave as intended. If any fork or archived repo appears, stop and fix the filter before proceeding.

---

## Task 4: Pilot on a single test repo and confirm the workflow runs

**Files:** none (live verification on one repo)

This task proves the workflow actually works before scaling out. Pick one low-stakes repo (the infra repo itself is a fine pilot, or create a throwaway `gh repo create dinoschristou/trufflehog-pilot --private`).

- [ ] **Step 1: Open the PR for the single pilot repo**

Run (replace `OWNER/PILOT`):
```bash
./scripts/trufflehog/rollout.sh --repo OWNER/PILOT
```
Expected: one `PR OWNER/PILOT` line. Open the PR in the browser and confirm the workflow file is correct.

- [ ] **Step 2: Confirm the clean-repo (green) path**

In the PR's Checks tab, confirm the `TruffleHog` job runs and **passes** on the clean repo (the `pull_request` diff scan triggers automatically).
Expected: green check, no findings.

- [ ] **Step 3: Confirm the detection (red) path**

IMPORTANT: `--results=verified` only fails on secrets TruffleHog can verify are *live*. A fake/random key will NOT trip it. To prove the red path, do ONE of:
  - (Preferred) Commit a real, disposable credential you then immediately revoke — e.g. create a scopeless GitHub PAT, commit it to a branch in the pilot repo, confirm the run goes **red**, then revoke the PAT and delete the branch.
  - (Wiring-only check) Temporarily change the pilot's workflow `extra_args` to `--results=verified,unknown --fail`, commit a dummy AWS-style key, and confirm the run goes red — then revert the `extra_args` back to `--results=verified`. This proves detection/wiring without a live secret, but does not exercise live verification.

Expected: a red run with the planted secret reported in the logs / job summary.

- [ ] **Step 4: Merge the pilot PR**

Merge it. Confirm the scheduled/`workflow_dispatch` path works:
```bash
gh workflow run "TruffleHog Secret Scan" -R OWNER/PILOT
gh run list -R OWNER/PILOT --workflow "TruffleHog Secret Scan" --limit 1
```
Expected: a `workflow_dispatch` run appears and completes (green on a clean repo). This exercises the full-history (`base: ""`) branch of the workflow.

---

## Task 5: Roll out to all repos

**Files:** none

- [ ] **Step 1: Run the full rollout**

Run:
```bash
./scripts/trufflehog/rollout.sh
```
Expected: one `PR <repo>` line per target repo, `SKIP` for the already-done pilot, and a final summary. Each opens a PR on its repo's default branch.

- [ ] **Step 2: Verify the open PRs**

Run:
```bash
gh search prs --owner dinoschristou --head ci/add-trufflehog --state open --limit 100
```
Expected: one open PR per target repo. Spot-check 2–3 to confirm the workflow file matches the template and the PR check ran.

- [ ] **Step 3: Confirm idempotency by re-running**

Run:
```bash
./scripts/trufflehog/rollout.sh --dry-run
```
Expected: every repo now shows `SKIP ... (open PR already exists)` (or `workflow already present` for merged ones). `opened/planned=0`. This proves re-running is safe.

- [ ] **Step 4: Merge the PRs**

Review and merge each PR (manually, or `gh pr merge <url> --squash` per repo once you're satisfied). After merge, each repo scans on every push/PR and weekly.

---

## Task 6: Document usage

**Files:**
- Create: `scripts/trufflehog/README.md`

- [ ] **Step 1: Write the README**

Create `scripts/trufflehog/README.md`:

```markdown
# TruffleHog secret scanning

Per-repo secret scanning across all non-archived, non-fork repos owned by
`dinoschristou`.

## Files
- `trufflehog.yml` — canonical workflow, copied into each repo at
  `.github/workflows/trufflehog.yml`.
- `rollout.sh` — opens one PR per repo adding the workflow. Idempotent.

## What the workflow does
- **push / pull_request:** scans only the new commits (fast feedback).
- **weekly schedule + manual dispatch:** scans the full git history.
- Fails the run **only on verified-live secrets** (`--results=verified --fail`),
  which sends GitHub's native failure email. Findings appear in the job summary.

## Rolling out
```bash
./rollout.sh --dry-run     # preview
./rollout.sh               # open PRs
./rollout.sh --repo OWNER/NAME   # single repo (testing)
```
Re-run any time to cover newly created repos — it skips repos that already have
the workflow or an open rollout PR.

## Testing the red path
`--results=verified` only fails on live, verifiable secrets — a random fake key
won't trip it. To test detection, commit a real disposable credential (e.g. a
scopeless GitHub PAT), confirm the run goes red, then revoke it.
```

- [ ] **Step 2: Commit**

```bash
git add scripts/trufflehog/README.md
git commit -m "docs(trufflehog): document workflow and rollout script"
```

---

## Self-Review Notes

- **Spec coverage:** workflow file (Task 1), 3 triggers + verified-only + fail (Task 1), GITHUB_TOKEN/no-PAT (implicit — `permissions: contents: read`, no secret referenced), full-history nuance via `base: ""` (Task 1), rollout script enumerating non-archived non-fork repos + idempotency (Tasks 2–3), dry-run + single-repo pilot testing (Tasks 3–4), full rollout (Task 5), docs (Task 6). All spec sections covered.
- **Testing honesty:** Task 4 Step 3 explicitly flags that `--results=verified` will not fail on fake secrets, and gives a real way to exercise the red path. This matches the spec's verified-only reporting choice.
- **No placeholders:** all file contents and commands are concrete; `OWNER/PILOT` and `OWNER/NAME` are clearly-marked user substitutions, not omitted content.
```
