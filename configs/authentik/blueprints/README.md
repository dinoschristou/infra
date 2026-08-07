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
- `authentik-server` is attached to two docker networks, but Traefik only lives on
  `proxy`. If Traefik's docker provider isn't pinned to `proxy`
  (`providers.docker.network` in `configs/traefik-vps/traefik.yml.j2`), it can dial the
  unreachable network and `auth.dinos.sh` hangs 30s and 504s — while forward-auth
  redirects still appear to work, which misleadingly looks like an authentik fault.
