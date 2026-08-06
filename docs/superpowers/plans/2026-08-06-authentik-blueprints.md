# Authentik Blueprints Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move Authentik's application-layer config (proxy provider, application,
outpost binding, groups) out of the Postgres DB and into version-controlled blueprint
files deployed by Ansible.

**Architecture:** Blueprint YAML files live in `configs/authentik/blueprints/`, are
copied to `/opt/stacks/authentik/blueprints/` by the existing `services` role (which
already recurses subdirectories), and are bind-mounted read-only into the
`authentik-worker` container at `/blueprints/custom`. The worker auto-discovers each
file as a `BlueprintInstance` and applies it on change and every 60 minutes.

**Tech Stack:** Authentik 5.2.14, Ansible, Docker Compose, YAML.

Design spec: `docs/superpowers/specs/2026-08-06-authentik-blueprints-design.md`

## Global Constraints

- Mount custom blueprints at **`/blueprints/custom`**, never `/blueprints` — the latter
  shadows the built-in `default/`, `system/` and `migrations/` blueprints and breaks
  the stock flows. (The official docs' example is wrong for our case.)
- `state: present` updates **only** the fields listed in `attrs`; omitted fields are
  left unchanged. Rely on this; do not enumerate fields defensively.
- Blueprint files are plain `.yaml` (not `.j2`) so the `services` role copies them
  verbatim. No Jinja templating, no secrets — the proxy provider's OAuth2 credentials
  are internal to Authentik and never appear in a blueprint.
- Never commit a decrypted `vars/vault.yaml`. A pre-commit hook enforces this and
  prints "Vault Encrypted. Safe to commit."
- Do not add `Co-Authored-By: Claude` trailers to commits or PRs.
- All work happens in the worktree `/Users/dinos/Code/infra/.claude/worktrees/authentik-blueprints`
  on branch `feat/authentik-blueprints`.
- Target host is `vps-01` only. Reach it via break-glass SSH:
  `ssh -p 4322 ubuntu@57.129.137.137`. The automation shell cannot route the tailnet.
- Deploy with `just config-only vps-01` **from the worktree**, then restart the worker
  when the compose file changes (`just` runs `--tags config`; the real tag is `configs`,
  so use the explicit `ansible-playbook` command given in each task).

## Reference: running a probe against live Authentik

Several tasks inspect live objects. Quoting through `ssh` + `docker exec` + `ak shell`
is fragile, so always write the probe to a file and pipe it over stdin:

```bash
cat > /tmp/probe.py <<'PYEOF'
from authentik.core.models import Application
print("APPS:", [a.slug for a in Application.objects.all()])
PYEOF
ssh -p 4322 ubuntu@57.129.137.137 \
  'docker exec -i authentik-worker ak shell -c "exec(open(0).read())"' < /tmp/probe.py
```

---

### Task 1: Deliver blueprints to the worker and adopt the SSO wiring

Creates the blueprints directory, mounts it, and adopts the existing proxy provider,
application and outpost binding. Because the blueprint describes the state that is
already live, a correct apply changes nothing — that is the test.

**Files:**
- Create: `configs/authentik/blueprints/sso-forward-auth.yaml`
- Modify: `configs/authentik/docker-compose.yaml` (add volume to `authentik-worker`)

**Interfaces:**
- Consumes: nothing.
- Produces: the blueprint entry id `dinos-forward-auth` (referenced by `!KeyOf` within
  this file only), and the deployed path `/opt/stacks/authentik/blueprints/`, which
  Tasks 2–4 add further files to.

- [ ] **Step 1: Capture the current live state as the baseline**

```bash
cat > /tmp/before.py <<'PYEOF'
from authentik.providers.proxy.models import ProxyProvider
from authentik.core.models import Application
from authentik.outposts.models import Outpost
p = ProxyProvider.objects.get(name="dinos-forward-auth")
for f in ["mode","external_host","internal_host","cookie_domain","skip_path_regex",
          "basic_auth_enabled","intercept_header_auth","access_token_validity",
          "refresh_token_validity"]:
    print(f"PROV {f} = {getattr(p,f)!r}")
print("PROV authorization_flow =", p.authorization_flow.slug)
print("PROV invalidation_flow =", p.invalidation_flow.slug)
print("PROV property_mappings =", sorted(m.managed for m in p.property_mappings.all()))
a = Application.objects.get(slug="dinos-sh")
print("APP name =", a.name, "| policy_engine_mode =", a.policy_engine_mode,
      "| provider =", a.provider.name)
o = Outpost.objects.get(managed="goauthentik.io/outposts/embedded")
print("OUTPOST providers =", sorted(x.name for x in o.providers.all()))
PYEOF
ssh -p 4322 ubuntu@57.129.137.137 \
  'docker exec -i authentik-worker ak shell -c "exec(open(0).read())"' < /tmp/before.py \
  | grep -E "^(PROV|APP|OUTPOST)" | tee /tmp/before.txt
```

Expected output (this is the known-good baseline measured 2026-08-06):

```
PROV mode = 'forward_domain'
PROV external_host = 'https://auth.dinos.sh'
PROV internal_host = ''
PROV cookie_domain = 'dinos.sh'
PROV skip_path_regex = ''
PROV basic_auth_enabled = False
PROV intercept_header_auth = True
PROV access_token_validity = 'hours=24'
PROV refresh_token_validity = 'days=30'
PROV authorization_flow = default-provider-authorization-implicit-consent
PROV invalidation_flow = default-provider-invalidation-flow
PROV property_mappings = ['goauthentik.io/providers/oauth2/scope-email', 'goauthentik.io/providers/oauth2/scope-entitlements', 'goauthentik.io/providers/oauth2/scope-openid', 'goauthentik.io/providers/oauth2/scope-profile', 'goauthentik.io/providers/proxy/scope-proxy']
APP name = dinos.sh protected | policy_engine_mode = any | provider = dinos-forward-auth
OUTPOST providers = ['dinos-forward-auth']
```

If it differs, stop — the blueprint below must be corrected to match reality before
applying, or the apply will change live config.

- [ ] **Step 2: Write the blueprint**

Create `configs/authentik/blueprints/sso-forward-auth.yaml`:

```yaml
---
# Domain-level forward-auth SSO for *.dinos.sh.
# Adopted from the live config on 2026-08-06. `state: present` updates only the
# fields listed under attrs; anything omitted is left untouched by authentik.
version: 1
metadata:
  name: dinos.sh forward-auth SSO
entries:
  - model: authentik_providers_proxy.proxyprovider
    id: dinos-forward-auth
    state: present
    identifiers:
      name: dinos-forward-auth
    attrs:
      mode: forward_domain
      external_host: https://auth.dinos.sh
      cookie_domain: dinos.sh
      intercept_header_auth: true
      basic_auth_enabled: false
      access_token_validity: hours=24
      refresh_token_validity: days=30
      authorization_flow:
        !Find [authentik_flows.flow, [slug, default-provider-authorization-implicit-consent]]
      invalidation_flow:
        !Find [authentik_flows.flow, [slug, default-provider-invalidation-flow]]
      property_mappings:
        - !Find [authentik_providers_oauth2.scopemapping, [managed, goauthentik.io/providers/oauth2/scope-openid]]
        - !Find [authentik_providers_oauth2.scopemapping, [managed, goauthentik.io/providers/oauth2/scope-email]]
        - !Find [authentik_providers_oauth2.scopemapping, [managed, goauthentik.io/providers/oauth2/scope-profile]]
        - !Find [authentik_providers_oauth2.scopemapping, [managed, goauthentik.io/providers/oauth2/scope-entitlements]]
        - !Find [authentik_providers_oauth2.scopemapping, [managed, goauthentik.io/providers/proxy/scope-proxy]]

  - model: authentik_core.application
    state: present
    identifiers:
      slug: dinos-sh
    attrs:
      name: dinos.sh protected
      policy_engine_mode: any
      provider: !KeyOf dinos-forward-auth

  # Only `providers` is set. The embedded outpost is authentik-managed; every other
  # field is deliberately left to authentik.
  - model: authentik_outposts.outpost
    state: present
    identifiers:
      managed: goauthentik.io/outposts/embedded
    attrs:
      providers:
        - !KeyOf dinos-forward-auth
```

All model labels used above were verified against `/blueprints/schema.json` in the
5.2.14 image on 2026-08-06: `authentik_providers_oauth2.scopemapping`,
`authentik_providers_oauth2.oauth2provider`, `authentik_policies.policybinding`,
`authentik_core.group`, `authentik_core.user`, `authentik_flows.flow`.

- [ ] **Step 3: Mount the directory into the worker**

In `configs/authentik/docker-compose.yaml`, in the `authentik-worker` service's
`volumes:` list, add the blueprints mount alongside the existing entries:

```yaml
    volumes:
      - ./media:/media
      - ./certs:/certs
      - ./custom-templates:/templates
      - ./blueprints:/blueprints/custom:ro
```

Do **not** add this to `authentik-server`; only the worker applies blueprints.

- [ ] **Step 4: Deploy and restart the worker**

The compose file changed, so the container must be recreated for the new mount.

```bash
cd /Users/dinos/Code/infra/.claude/worktrees/authentik-blueprints
ansible-playbook -i inventory/hosts.yaml site.yaml --tags configs --limit vps-01
ssh -p 4322 ubuntu@57.129.137.137 \
  'cd /opt/stacks/authentik && docker compose up -d authentik-worker'
```

Expected: playbook `failed=0`; the worker is recreated.

- [ ] **Step 5: Verify the blueprint was discovered and applied cleanly**

```bash
cat > /tmp/status.py <<'PYEOF'
from authentik.blueprints.models import BlueprintInstance
for b in BlueprintInstance.objects.filter(path__startswith="custom/"):
    print("BP", b.path, "|", b.status, "|", (b.last_applied_hash or "")[:12])
    if b.status != "successful":
        print("   ERROR:", b.metadata, b.last_applied)
PYEOF
ssh -p 4322 ubuntu@57.129.137.137 \
  'docker exec -i authentik-worker ak shell -c "exec(open(0).read())"' < /tmp/status.py \
  | grep -E "^(BP|   ERROR)"
```

Expected: `BP custom/sso-forward-auth.yaml | successful | <hash>`

A failed blueprint is otherwise silent — this status is the only signal. If it is not
`successful`, read the error and fix the blueprint; do not proceed.

- [ ] **Step 6: Verify nothing drifted**

Re-run the Step 1 probe and diff against the baseline:

```bash
ssh -p 4322 ubuntu@57.129.137.137 \
  'docker exec -i authentik-worker ak shell -c "exec(open(0).read())"' < /tmp/before.py \
  | grep -E "^(PROV|APP|OUTPOST)" > /tmp/after.txt
diff /tmp/before.txt /tmp/after.txt && echo "NO DRIFT"
```

Expected: `NO DRIFT`. Any diff means the blueprint misdescribes the live config —
correct the blueprint to match, re-apply, and re-check.

- [ ] **Step 7: Verify SSO still works end to end**

```bash
curl -s -o /dev/null -m 15 -w "UI  http=%{http_code} redirect=%{redirect_url}\n" https://freshrss.dinos.sh/
curl -s -o /dev/null -m 15 -w "API http=%{http_code}\n" https://freshrss.dinos.sh/api/fever.php
curl -s -o /dev/null -m 15 -w "WAL http=%{http_code} redirect=%{redirect_url}\n" https://read.dinos.sh/
```

Expected: UI `302` to `https://auth.dinos.sh/application/o/authorize/…`; API `200`;
wallabag `302` to the same authorize URL. Then log in through the browser once to
confirm the flow completes.

- [ ] **Step 8: Commit**

```bash
git add configs/authentik/blueprints/sso-forward-auth.yaml configs/authentik/docker-compose.yaml
git commit -m "feat(authentik): manage forward-auth SSO wiring as a blueprint"
```

---

### Task 2: Remove the dead FreshRSS OIDC objects

The abandoned OIDC attempt left an application and an OAuth2 provider behind. Nothing
uses them (FreshRSS is on forward-auth). Deleting them declaratively keeps git matching
reality.

**Files:**
- Create: `configs/authentik/blueprints/cleanup.yaml`

**Interfaces:**
- Consumes: the deployed blueprints directory from Task 1.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Confirm they exist and nothing references them**

```bash
cat > /tmp/oidc.py <<'PYEOF'
from authentik.core.models import Application
from authentik.providers.oauth2.models import OAuth2Provider
print("APPS:", [a.slug for a in Application.objects.all()])
print("OAUTH2:", [(p.name, p.client_id) for p in OAuth2Provider.objects.all()])
PYEOF
ssh -p 4322 ubuntu@57.129.137.137 \
  'docker exec -i authentik-worker ak shell -c "exec(open(0).read())"' < /tmp/oidc.py \
  | grep -E "^(APPS|OAUTH2):"
```

Expected: `APPS` contains both `dinos-sh` and `freshrss`; `OAUTH2` contains `freshrss`
and `dinos-forward-auth`. The `dinos-forward-auth` OAuth2 provider is the proxy
provider's internal backing object — **do not delete it**.

- [ ] **Step 2: Write the cleanup blueprint**

Create `configs/authentik/blueprints/cleanup.yaml`:

```yaml
---
# Removes the dead objects from the abandoned FreshRSS OIDC attempt (2026-08-02).
# FreshRSS is protected by forward-auth via the `dinos-sh` application instead.
# These entries stay in git as no-ops so a rebuilt instance never recreates them.
version: 1
metadata:
  name: cleanup - abandoned freshrss OIDC
entries:
  - model: authentik_core.application
    state: absent
    identifiers:
      slug: freshrss

  - model: authentik_providers_oauth2.oauth2provider
    state: absent
    identifiers:
      name: freshrss
```

- [ ] **Step 3: Deploy**

The compose file is unchanged, so no container restart is needed; the worker picks up
the new file automatically.

```bash
cd /Users/dinos/Code/infra/.claude/worktrees/authentik-blueprints
ansible-playbook -i inventory/hosts.yaml site.yaml --tags configs --limit vps-01
```

Expected: playbook `failed=0`.

- [ ] **Step 4: Verify the objects are gone and the survivor is intact**

Re-run the Step 1 probe.

Expected: `APPS` is now `['dinos-sh']`; `OAUTH2` still contains `dinos-forward-auth`
but no longer `freshrss`.

If the file was not picked up within a minute, force discovery:

```bash
ssh -p 4322 ubuntu@57.129.137.137 \
  'docker exec authentik-worker ak shell -c "from authentik.blueprints.v1.tasks import blueprints_discovery; blueprints_discovery.send()"'
```

- [ ] **Step 5: Verify SSO is unaffected**

Re-run the three `curl` checks from Task 1 Step 7. Expected: identical results.

- [ ] **Step 6: Commit**

```bash
git add configs/authentik/blueprints/cleanup.yaml
git commit -m "feat(authentik): remove abandoned freshrss OIDC objects via blueprint"
```

---

### Task 3: Declare the access group (no binding yet)

Creates `dinos-sh-users` with the `dinos` user as a member. **No policy binding is
added in this task** — the group has no effect on access until Task 4. This split is
deliberate: it guarantees membership is correct before anything starts enforcing it.

**Files:**
- Create: `configs/authentik/blueprints/groups.yaml`

**Interfaces:**
- Consumes: the deployed blueprints directory from Task 1.
- Produces: group `dinos-sh-users`, referenced by Task 4's policy binding via
  `!Find [authentik_core.group, [name, dinos-sh-users]]`.

- [ ] **Step 1: Write the group blueprint**

Create `configs/authentik/blueprints/groups.yaml`:

```yaml
---
# Access group for the dinos.sh protected application.
# Users are referenced by !Find, never declared here — passwords and MFA state
# must not enter git.
# NOTE: this group does not gate anything until the policy binding is added.
version: 1
metadata:
  name: dinos.sh access groups
entries:
  - model: authentik_core.group
    id: dinos-sh-users
    state: present
    identifiers:
      name: dinos-sh-users
    attrs:
      users:
        - !Find [authentik_core.user, [username, dinos]]
```

- [ ] **Step 2: Deploy**

```bash
cd /Users/dinos/Code/infra/.claude/worktrees/authentik-blueprints
ansible-playbook -i inventory/hosts.yaml site.yaml --tags configs --limit vps-01
```

- [ ] **Step 3: Verify the group exists with the right membership**

```bash
cat > /tmp/group.py <<'PYEOF'
from authentik.core.models import Group
g = Group.objects.filter(name="dinos-sh-users").first()
print("GROUP:", g and g.name)
print("MEMBERS:", g and sorted(u.username for u in g.users.all()))
PYEOF
ssh -p 4322 ubuntu@57.129.137.137 \
  'docker exec -i authentik-worker ak shell -c "exec(open(0).read())"' < /tmp/group.py \
  | grep -E "^(GROUP|MEMBERS):"
```

Expected: `GROUP: dinos-sh-users` and `MEMBERS: ['dinos']`.

**Gate:** if `MEMBERS` is empty or missing `dinos`, do not start Task 4 — binding an
empty group locks the browser UI for everyone.

- [ ] **Step 4: Commit**

```bash
git add configs/authentik/blueprints/groups.yaml
git commit -m "feat(authentik): declare dinos-sh-users access group"
```

---

### Task 4: Enforce the group with a policy binding

This is the only task that changes live access control. Before it, any authenticated
Authentik user can reach the protected browser UIs; after it, only members of
`dinos-sh-users` can. The FreshRSS API is unaffected — it never reaches Authentik.

**Files:**
- Modify: `configs/authentik/blueprints/groups.yaml` (append the binding entry)

**Interfaces:**
- Consumes: group `dinos-sh-users` from Task 3.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Re-confirm membership immediately before enforcing**

Re-run the Task 3 Step 3 probe. Expected: `MEMBERS: ['dinos']`. Do not continue
otherwise.

- [ ] **Step 2: Append the policy binding**

Add this entry to the end of the `entries:` list in
`configs/authentik/blueprints/groups.yaml`:

```yaml
  # Restricts the dinos.sh application to members of dinos-sh-users.
  # Rollback: set state to absent (or delete in the UI *and* push that change —
  # a UI-only deletion is re-created by this blueprint within 60 minutes).
  - model: authentik_policies.policybinding
    state: present
    identifiers:
      target: !Find [authentik_core.application, [slug, dinos-sh]]
      group: !Find [authentik_core.group, [name, dinos-sh-users]]
      order: 0
    attrs:
      enabled: true
      negate: false
      timeout: 30
```

- [ ] **Step 3: Deploy**

```bash
cd /Users/dinos/Code/infra/.claude/worktrees/authentik-blueprints
ansible-playbook -i inventory/hosts.yaml site.yaml --tags configs --limit vps-01
```

- [ ] **Step 4: Verify the binding exists and the blueprint applied cleanly**

```bash
cat > /tmp/binding.py <<'PYEOF'
from authentik.policies.models import PolicyBinding
from authentik.core.models import Application
from authentik.blueprints.models import BlueprintInstance
a = Application.objects.get(slug="dinos-sh")
print("BINDINGS:", [(b.order, b.group and b.group.name, b.enabled)
                    for b in PolicyBinding.objects.filter(target=a.pbm_uuid)])
for b in BlueprintInstance.objects.filter(path__startswith="custom/"):
    print("BP", b.path, "|", b.status)
PYEOF
ssh -p 4322 ubuntu@57.129.137.137 \
  'docker exec -i authentik-worker ak shell -c "exec(open(0).read())"' < /tmp/binding.py \
  | grep -E "^(BINDINGS|BP)"
```

Expected: `BINDINGS: [(0, 'dinos-sh-users', True)]` and every `BP` line `successful`.

- [ ] **Step 5: Verify access in a browser — the real test**

In a normal browser session logged in as `dinos`, load `https://read.dinos.sh/` and
`https://freshrss.dinos.sh/`. Both must load.

Then confirm the API is still open:

```bash
curl -s -o /dev/null -m 15 -w "API http=%{http_code}\n" https://freshrss.dinos.sh/api/fever.php
```

Expected: `200`.

**If locked out:** delete the binding in the Authentik admin UI to regain access
immediately, then revert this step's change in git (or set `state: absent`) and
re-deploy — otherwise the blueprint recreates the binding within 60 minutes.

- [ ] **Step 6: Commit**

```bash
git add configs/authentik/blueprints/groups.yaml
git commit -m "feat(authentik): restrict dinos.sh application to dinos-sh-users"
```

---

### Task 5: Document the new workflow and fix the stale note

**Files:**
- Modify: `CLAUDE.md:82`
- Create: `configs/authentik/blueprints/README.md`

**Interfaces:**
- Consumes: everything above.
- Produces: nothing.

- [ ] **Step 1: Fix the stale CLAUDE.md line**

Replace line 82:

```markdown
- **Identity**: Authentik (config exists in `/configs/authentik/` but not deployed)
```

with:

```markdown
- **Identity**: Authentik on vps-01 (`auth.dinos.sh`), providing forward-auth SSO for the dinos.sh services. Application-layer config (providers, applications, groups, policies) is declared in `configs/authentik/blueprints/` and applied by the worker — see that directory's README.
```

- [ ] **Step 2: Write the directory README**

Create `configs/authentik/blueprints/README.md`:

```markdown
# Authentik blueprints

Declarative application-layer config for the Authentik instance on vps-01. These files
are copied to `/opt/stacks/authentik/blueprints/` by the `services` role and mounted
read-only into `authentik-worker` at `/blueprints/custom`.

The worker applies them on file change and re-applies every 60 minutes, so **git is
authoritative**: manual edits in the admin UI to any field declared here are reverted
within the hour. Change these files instead.

| File | Purpose |
| --- | --- |
| `sso-forward-auth.yaml` | The `dinos-forward-auth` proxy provider, the `dinos-sh` application, and the embedded outpost binding |
| `groups.yaml` | The `dinos-sh-users` group and the policy binding restricting the application to it |
| `cleanup.yaml` | Tombstones for the abandoned FreshRSS OIDC objects |

## Gotchas

- Mount at `/blueprints/custom`, never `/blueprints` — the latter shadows authentik's
  built-in blueprints and breaks the stock flows.
- `state: present` updates only the fields under `attrs`; omitted fields are untouched.
  Other states: `created` (create once, never update), `must_created` (fail if exists),
  `absent` (delete).
- Users are referenced with `!Find`, never declared — passwords and MFA state must not
  enter git.
- A failed blueprint is silent. Check status with:
  `docker exec authentik-worker ak shell -c "from authentik.blueprints.models import BlueprintInstance; print([(b.path, b.status) for b in BlueprintInstance.objects.filter(path__startswith='custom/')])"`
- The FreshRSS `/api/` path bypasses Authentik entirely (a separate Traefik router).
  Policy bindings here cannot restrict it.
```

- [ ] **Step 3: Verify the docs match reality**

Confirm the file table lists exactly the files present:

```bash
ls configs/authentik/blueprints/
```

Expected: `README.md`, `cleanup.yaml`, `groups.yaml`, `sso-forward-auth.yaml`.

- [ ] **Step 4: Commit and open the PR**

```bash
git add CLAUDE.md configs/authentik/blueprints/README.md
git commit -m "docs(authentik): document blueprint workflow, fix stale deployment note"
git push -u origin feat/authentik-blueprints
gh pr create --title "feat(authentik): manage application-layer config as blueprints" \
  --body "Implements docs/superpowers/specs/2026-08-06-authentik-blueprints-design.md"
```

---

## Rollback

| Symptom | Action |
| --- | --- |
| Locked out of the browser UIs | Delete the policy binding in the admin UI, then revert Task 4 in git and redeploy (a UI-only deletion is recreated within 60 minutes) |
| A blueprint applies wrong values | Set the offending `BlueprintInstance` to `enabled=False` in the UI to stop enforcement, then fix the file |
| Stock flows broken | Check the worker mount is `/blueprints/custom`, not `/blueprints`; fix and recreate the worker |
| Total loss | The config is three objects; recreate by hand in the UI using the baseline values in Task 1 Step 1 |

## Out of scope

- Users, MFA devices, tokens — cannot round-trip through a blueprint.
- Built-in flows and stages — authentik ships these as its own managed blueprints.
- Fixing `pg-backup` empty dumps (issue #92).
- The unauthenticated exporter routers (issue #91).
