# Filebrowser, Dozzle — Design

**Date:** 2026-05-31
**Scope:** Add two new self-hosted ops services to the home lab: Filebrowser (file management) and Dozzle (Docker logs). Both deployed per-host and routed via Traefik with the existing `services` role.

## Goals

- File management UI on every local Docker VM, rooted at `/opt/knxcloud`.
- Per-host Docker log viewer (Dozzle) so logs are inspected in the context of a single host.
- Both sit behind Traefik with Cloudflare-issued certs and are fronted by the existing Traefik basic-auth middleware (matching the Traefik dashboard's auth model).
- Avoid host-port collisions. Traefik-only routing with no published host ports.

## Non-goals

- Filebrowser on `external-01` (cloud server). No clear need; would require a public route for what is essentially admin tooling.
- Migrating away from Portainer or Uptime Kuma. New services are additive.

## Architecture

### Deployment matrix

| Service | mon | infra | apps | mqtt | nvr | external-01 |
|---|---|---|---|---|---|---|
| filebrowser | ✓ | ✓ | ✓ | ✓ | ✓ | — |
| dozzle | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |

### Port mapping

The existing `uptimekuma` config sets the precedent: no host port, route everything through Traefik. We follow that throughout.

| Service | Container port | Host port | Traefik route |
|---|---|---|---|
| filebrowser | 80 | none | `files.<host>.knxcloud.io` |
| dozzle | 8080 | none | `dozzle.<host>.knxcloud.io` (local) / `dozzle.dinos.sh` (external-01) |

**No new host ports are introduced.**

### Auth model

Both services are fronted by the **Traefik basic-auth middleware** that already exists for the Traefik dashboard:

```yaml
labels:
  - "traefik.http.routers.<svc>.middlewares=traefik-auth@docker"
```

This re-uses `TRAEFIK_DASHBOARD_CREDENTIALS` from `.env` — no second credential set to manage. Filebrowser's own user database is still used for actual file-level permissions (single admin user, default password rotated on first login). Dozzle runs with `DOZZLE_AUTH_PROVIDER=none` because Traefik gates access.

## Files added

```
configs/filebrowser/
  docker-compose.yaml
  .env.st
configs/dozzle/
  docker-compose.yaml
  .env.st
docs/superpowers/specs/2026-05-31-filebrowser-dozzle-beszel-design.md
```

## Files modified

- `group_vars/all.yaml` — add two Renovate-managed version pins:
  - `filebrowser_version` (datasource: docker, depName: filebrowser/filebrowser)
  - `dozzle_version` (datasource: docker, depName: amir20/dozzle)
- `host_vars/mon.yaml` — append `filebrowser`, `dozzle` to `services_configs`.
- `host_vars/infra.yaml` — append `filebrowser`, `dozzle`.
- `host_vars/apps.yaml` — append `filebrowser`, `dozzle`.
- `host_vars/mqtt.yaml` — append `filebrowser`, `dozzle`.
- `host_vars/nvr.yaml` — append `filebrowser`, `dozzle`.
- `host_vars/external-01.yaml` — append `dozzle`.

## Per-service detail

### Filebrowser

- Image: `filebrowser/filebrowser:{{ filebrowser_version }}`
- Volumes:
  - `/opt/knxcloud:/srv` — entire stack dir is browsable/manageable.
  - `./database:/database` — sqlite DB for filebrowser users.
  - `./config:/config` — `settings.json` if needed.
- `required_folders:` `database`, `config`
- Labels: Traefik HTTPS router on `files.${FULL_DOMAIN}`, `traefik-auth@docker` middleware.
- No published host port.
- First-login admin/admin → must be changed manually on each host.

### Dozzle

- Image: `amir20/dozzle:{{ dozzle_version }}`
- Volumes:
  - `/var/run/docker.sock:/var/run/docker.sock:ro`
- Env:
  - `DOZZLE_AUTH_PROVIDER=none` (Traefik handles auth)
  - `DOZZLE_LEVEL=info`
- Labels: Traefik HTTPS router on `dozzle.${FULL_DOMAIN}`, `traefik-auth@docker` middleware.
- No published host port.

## Testing / verification

1. `just config-only <host>` for each modified host_vars to verify Jinja templating succeeds.
2. `just run-machine mon` — confirm:
   - `https://files.mon.knxcloud.io` prompts for Traefik basic-auth then shows Filebrowser login.
   - `https://dozzle.mon.knxcloud.io` prompts for Traefik basic-auth then shows the Dozzle container list.
3. Repeat per host with `just run-machine <host>`; `just run-ext` for external-01.
4. Confirm no UFW changes were needed — none of the new services expose host ports.

## Risks

- **Filebrowser at `/opt/knxcloud` is powerful** — admin user can read every service's `.env`, including ones rendered from vault. Acceptable because access is gated by Traefik basic-auth + Filebrowser's own password, but worth a callout. Do not expose filebrowser routes via Cloudflare tunnel.

## Out of scope (follow-ups)

- Filebrowser settings provisioning (declarative user/branding config). Acceptable to leave as a manual first-login step initially.
- Dozzle agent mode (central UI + agents) — re-evaluate if per-host turns out painful.
