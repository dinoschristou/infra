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
