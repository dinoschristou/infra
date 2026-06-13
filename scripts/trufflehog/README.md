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
