# Authentik application-layer config as blueprints

Date: 2026-08-06
Status: approved design, not yet implemented

## Problem

Authentik's config splits into two layers. The **deployment layer** (compose file,
image versions, env) already lives in `configs/authentik/` and deploys via Ansible —
versioned and reviewable like everything else in this repo. The **application layer**
(providers, applications, outposts, groups, policies) lives only in Authentik's
Postgres DB. Nothing in git describes it.

That means the SSO wiring guarding the public `dinos.sh` services cannot be rebuilt
from source, and changes to it can only be made by clicking through the admin UI.

## Goals

1. **Rebuildability** — if the Authentik DB is lost, the SSO wiring can be recreated
   from git.
2. **Reviewable edits** — new protected apps or policy changes arrive as file changes
   in a PR, deployed through the normal Ansible flow. No live API edits against prod.

Both weigh equally.

## Current live state (measured 2026-08-06, Authentik 5.2.14)

Smaller than expected. The entire hand-built application layer is:

| Object | Value |
| --- | --- |
| ProxyProvider `dinos-forward-auth` | `mode=forward_domain`, `external_host=https://auth.dinos.sh`, `cookie_domain=dinos.sh`, `internal_host=''`, `skip_path_regex=''`, `basic_auth_enabled=False`, `intercept_header_auth=True`, `access_token_validity=hours=24`, `refresh_token_validity=days=30` |
| — its flows | `authorization_flow=default-provider-authorization-implicit-consent`, `invalidation_flow=default-provider-invalidation-flow`, `authentication_flow=None` |
| — its property mappings | the 5 default managed mappings (openid, email, profile, Application Entitlements, Proxy outpost) |
| Application `dinos-sh` | `name='dinos.sh protected'`, `policy_engine_mode=any`, `provider=dinos-forward-auth` |
| Outpost | `authentik Embedded Outpost`, `type=proxy`, `managed=goauthentik.io/outposts/embedded`, `providers=[dinos-forward-auth]` |
| Groups | only built-ins (`authentik Admins`, `authentik Read-only`) — **no custom groups** |
| Policy bindings on `dinos-sh` | **none** |
| Custom flows | none |
| Dead OIDC leftovers | Application `freshrss` + OAuth2Provider `freshrss` (from the abandoned OIDC attempt) |

Two facts from this table drive the design:

- **`skip_path_regex` is empty.** The FreshRSS `/api/` bypass is *not* an Authentik
  concern — it is a separate Traefik router (`freshrss-api`) that simply omits the
  `authentik@file` middleware and applies a rate limit instead. This work does not
  touch it.
- **There are no policy bindings.** Today, *any* authenticated Authentik user can
  reach the protected services. Introducing groups therefore changes access control;
  it is not merely describing what already exists. See Risks.

### The FreshRSS API is outside the SSO boundary

Verified live on 2026-08-06:

| Path | Result |
| --- | --- |
| `/api/greader.php/accounts/ClientLogin` | `400` — reached FreshRSS itself |
| `/api/fever.php` | `200` — reached FreshRSS itself |
| `/` (UI) | `302` → `auth.dinos.sh/application/o/authorize/…` |

The API never consults Authentik. The bypass is the higher-priority `freshrss-api`
Traefik router, which omits the `authentik@file` middleware and applies a rate limit
keyed on `Cf-Connecting-Ip`.

Two consequences, both load-bearing for this design:

1. Nothing in this work touches API access — not the blueprint adoption, and not the
   provider's `skip_path_regex` (which is empty and unused).
2. **Adding groups cannot break mobile RSS sync.** A policy binding gates the Authentik
   *application*, and the API path never reaches it. The lockout risk in Risks applies
   to the browser UI only.

The corollary is that the API is protected solely by FreshRSS's own API password plus
that rate limit — SSO contributes nothing to it. That is a deliberate, pre-existing
tradeoff to keep mobile sync working, unchanged by this work. It also means groups can
never be used to restrict API access; that would require a different mechanism.

## Findings from the manuals

Checked against the official Authentik documentation and `/blueprints/schema.json`
shipped in the 5.2.14 image. Three corrections to the initial design:

1. **Mount path.** The container looks for blueprints in `/blueprints`, and the docs'
   example is `./blueprints:/blueprints:ro`. Following that literally would **shadow
   the built-in `default/`, `system/` and `migrations/` blueprints** and break the
   stock flows. Discovery recurses into subdirectories — confirmed by existing
   `BlueprintInstance` paths such as `default/flow-oobe.yaml` and
   `migrations/migrate-prompt-name.yaml` — so custom blueprints mount at
   **`/blueprints/custom`** instead.

2. **`state` semantics make adoption safe.** Per the docs, `state: present` (the
   default) "creates the object if it doesn't exist, or updates the fields specified
   in attrs if it does exist… **fields not in attrs are left unchanged**". The
   original worry — that adopting an existing object would reset omitted fields — was
   wrong. Also available: `created` (create once, never update, preserves manual
   changes), `must_created` (fail if it exists), and `absent` (delete).

3. **No secrets are involved.** The blueprint schema for
   `authentik_providers_proxy.proxyprovider` has no client id/secret fields; those are
   generated internally and read from the DB by the embedded outpost. No vault or
   `.env` changes are needed.

Schema field names confirmed for the models used here:

- `proxyprovider`: `name, mode, external_host, internal_host, cookie_domain,
  skip_path_regex, basic_auth_enabled, intercept_header_auth, access_token_validity,
  refresh_token_validity, authorization_flow, invalidation_flow, authentication_flow,
  property_mappings, certificate, …`
- `application`: `name, slug, provider, policy_engine_mode, meta_launch_url, group, …`
- `outpost`: `name, type, providers, config, managed, service_connection`
- `group`: `name, users, parents, roles, attributes, is_superuser`
- `policybinding`: `target, order, policy, group, user, enabled, negate, failure_result,
  timeout` — exactly one of `policy`/`group`/`user`; no `name` field

Tag syntax confirmed: `!Find [<model>, [<key>, <value>]]` resolves an existing object
to its primary key; `!KeyOf <id>` references another entry in the same blueprint.

## Design

### Approach

Hand-authored blueprints, referencing flows and property mappings by `!Find`, listing
only the fields actually set.

Rejected alternatives:

- **`ak export_blueprint`** — faithful but verbose, embeds internal primary keys, and
  diffs badly in review. Poor fit for goal 2.
- **Terraform provider (`goauthentik/authentik`)** — introduces a second toolchain and
  a state file to store and secure, in a repo that is otherwise pure Ansible.

### Delivery

```
configs/authentik/blueprints/*.yaml
  → services role (already recurses subdirectories, copies non-.j2 files verbatim)
  → /opt/stacks/authentik/blueprints/
  → bind-mounted read-only into authentik-worker at /blueprints/custom
```

Only the **worker** needs the mount; it is the component that applies blueprints. The
worker auto-discovers each file as a `BlueprintInstance`, applies it, re-applies on
file modification, and re-applies on a 60-minute schedule.

**Operational consequence:** git becomes authoritative for the managed fields. Manual
UI edits to those fields will be reverted within the hour. This is accepted and is the
point of the change.

### Files

**`configs/authentik/blueprints/sso-forward-auth.yaml`** — the SSO wiring:

- `authentik_providers_proxy.proxyprovider` identified by `name: dinos-forward-auth`,
  with the field values in the table above; flows and property mappings via `!Find`.
- `authentik_core.application` identified by `slug: dinos-sh`, provider via `!KeyOf`.
- `authentik_outposts.outpost` identified by
  `managed: goauthentik.io/outposts/embedded`, with **only** `providers` in `attrs`,
  so the rest of the authentik-managed embedded outpost is left alone.

**`configs/authentik/blueprints/groups.yaml`** — access control:

- `authentik_core.group` named `dinos-sh-users`, with `users` populated by
  `!Find [authentik_core.user, [username, dinos]]`. This *references* the user rather
  than declaring one, so no passwords or MFA state enter git.
- `authentik_policies.policybinding` targeting the `dinos-sh` application and binding
  the group.

These two entries land in **separate steps**, not together: the group ships and its
membership is verified first, and only then is the binding added. See Risks. The file
therefore contains just the group on its first deployment.

**`configs/authentik/blueprints/cleanup.yaml`** — the dead OIDC leftovers, declared
`state: absent`: application `freshrss` and OAuth2 provider `freshrss`. Doing this
declaratively rather than by hand keeps git matching reality and makes the deletion
reviewable. The entries remain as harmless no-ops afterwards.

### Compose change

Add to `authentik-worker` in `configs/authentik/docker-compose.yaml`:

```yaml
      - ./blueprints:/blueprints/custom:ro
```

### Documentation

Fix `CLAUDE.md:82`, which still says Authentik's "config exists in `/configs/authentik/`
but not deployed". It is deployed on vps-01.

## Risks

**Access-control change (highest risk).** There are no policy bindings today, so every
authenticated user can reach the protected services. Adding `dinos-sh-users` plus a
binding restricts access to that group's members. If the binding lands before the
membership resolves, it locks the user out of their own public services.

Mitigation: land the group and its membership first and verify `dinos` is a member,
then add the binding in a second step. Rollback is deleting the binding — either in
the UI (fastest, when locked out) or by setting `state: absent`. Note that a UI
deletion will be re-created by the blueprint within 60 minutes, so the git change must
follow.

**Adopting the embedded outpost.** It is authentik-managed. The blueprint sets only
`providers`, leaving all other fields to Authentik, which should avoid contention —
but this is the least certain part of the design and must be verified by inspecting
the outpost after the first apply.

**Blueprint shadowing.** Mounting at `/blueprints` instead of `/blueprints/custom`
would break the stock flows. Called out explicitly because the official docs' example
does exactly this.

No rollback via database dump: with the config this small, hand-rebuilding is a few
minutes of UI work, and issue #92 indicates `pg-backup` is currently producing empty
dumps anyway.

## Verification

1. Capture the live field values of the provider, application and outpost before
   applying.
2. Apply, then confirm every `BlueprintInstance` reports `successful` — a failed
   blueprint is silent apart from its status.
3. Re-capture and diff the object fields; nothing should have changed on this first
   apply, since the blueprints describe the existing state.
4. Functional check: `freshrss.dinos.sh` and `read.dinos.sh` still require login and
   still authenticate successfully; `freshrss.dinos.sh/api/` still bypasses auth
   (guards the Traefik router, unrelated to the provider, but it is the path that
   breaks most visibly).
5. Confirm the `freshrss` OIDC application and provider are gone.
6. Only then add the policy binding, and re-run step 4.

## Out of scope

- Users, MFA devices, tokens — cannot round-trip through a blueprint.
- Built-in flows and stages — Authentik ships these as its own managed blueprints.
- Fixing `pg-backup` empty dumps (issue #92).
- The unauthenticated exporter routers (issue #91).
