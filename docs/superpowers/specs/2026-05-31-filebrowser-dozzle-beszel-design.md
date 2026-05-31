# Filebrowser, Dozzle, Beszel — Design

**Date:** 2026-05-31
**Scope:** Add three new self-hosted ops services to the home lab: Filebrowser (file management), Dozzle (Docker logs), Beszel (server monitoring). All routed via Traefik with the existing `services` role.

## Goals

- File management UI on every local Docker VM, rooted at `/opt/knxcloud`.
- Per-host Docker log viewer (Dozzle) so logs are inspected in the context of a single host.
- Central server monitoring (Beszel hub) on `mon`, with agents on every Docker host including external-01.
- All three sit behind Traefik with Cloudflare-issued certs. Public-facing routes use the existing Traefik basic-auth pattern (matching the Traefik dashboard).
- Avoid host-port collisions. Prefer Traefik-only routing with no published host ports unless required by the protocol.

## Non-goals

- Beszel agents on `pve1` / `pve2` Proxmox hypervisors. Deferred to a follow-up — Proxmox hosts are not Docker hosts and need a binary/systemd install plus an Ansible role.
- Filebrowser on `external-01` (cloud server). No clear need; would require a public route for what is essentially admin tooling.
- Migrating away from Portainer or Uptime Kuma. New services are additive.

## Architecture

### Deployment matrix

| Service | mon | infra | apps | mqtt | nvr | external-01 |
|---|---|---|---|---|---|---|
| filebrowser | ✓ | ✓ | ✓ | ✓ | ✓ | — |
| dozzle | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| beszel (hub) | ✓ | — | — | — | — | — |
| beszel-agent | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ (WebSocket mode) |

### Port mapping

The existing `uptimekuma` config sets the precedent: no host port, route everything through Traefik. We follow that wherever possible.

| Service | Container port | Host port | Traefik route |
|---|---|---|---|
| filebrowser | 80 | none | `files.<host>.knxcloud.io` |
| dozzle | 8080 | none | `dozzle.<host>.knxcloud.io` (local) / `dozzle.<host>.dinos.sh` (external-01) |
| beszel hub | 8090 | none | `beszel.mon.knxcloud.io` |
| beszel-agent (local) | 45876 | 45876 (LAN, hub → agent) | n/a |
| beszel-agent (external-01) | 45876 | none — WebSocket out to hub | n/a |

**Port 45876** is the only new host port introduced. A grep of `configs/` confirms it is unused everywhere. It only needs to be reachable from `mon` over the LAN; UFW rules can scope it to mon's IP.

For the external-01 agent, the hub cannot reach a port behind Cloudflare without exposing it publicly. Beszel ≥ 0.9 supports a WebSocket "Universal Token" mode where the **agent** opens an outbound connection to the hub. The hub must be reachable from external-01 — it already is, via `beszel.mon.knxcloud.io` resolving through Cloudflare/Tailscale or direct tunnel as the rest of the cross-network monitoring works (`monitoring-client` on external-01 → Prometheus on mon).

### Auth model

Both Filebrowser and Dozzle are fronted by the **Traefik basic-auth middleware** that already exists for the Traefik dashboard:

```yaml
labels:
  - "traefik.http.routers.<svc>.middlewares=traefik-auth"
```

This re-uses `TRAEFIK_DASHBOARD_CREDENTIALS` from `.env` — no second credential set to manage. Filebrowser's own user database is still used for actual file-level permissions (single admin user, default password rotated on first login). Dozzle runs with `DOZZLE_AUTH_PROVIDER=none` because Traefik gates access.

Beszel has built-in auth (single admin account, email/password) and does not need Traefik basic-auth on top.

### Beszel hub ↔ agent trust

On first startup, the Beszel hub generates an SSH key pair at `/beszel_data/id_ed25519`. The **public key** is stored in `vars/vault.yaml` as `beszel_hub_pubkey` and injected into each agent via the `KEY` env var. Storing a pubkey in vault is overkill from a secrecy standpoint but keeps all Beszel config in one place and matches the project convention of "anything templated into a service `.env` lives in vault."

Bootstrap order:
1. Deploy Beszel hub on `mon`. Manually pull `/opt/knxcloud/beszel/data/id_ed25519.pub` after first run.
2. Add the pubkey to `vars/vault.yaml`.
3. Deploy agents on the remaining hosts.

This one-time bootstrap is documented in a `README.md` inside `configs/beszel/`.

## Files added

```
configs/filebrowser/
  docker-compose.yaml
  .env.st
configs/dozzle/
  docker-compose.yaml
  .env.st
configs/beszel/
  docker-compose.yaml
  .env.st
  README.md                # bootstrap instructions
configs/beszel-agent/
  docker-compose.yaml
  .env.st
docs/superpowers/specs/2026-05-31-filebrowser-dozzle-beszel-design.md
```

## Files modified

- `group_vars/all.yaml` — add four Renovate-managed version pins:
  - `filebrowser_version` (datasource: docker, depName: filebrowser/filebrowser)
  - `dozzle_version` (datasource: docker, depName: amir20/dozzle)
  - `beszel_version` (datasource: docker, depName: henrygd/beszel)
  - `beszel_agent_version` (datasource: docker, depName: henrygd/beszel-agent)
- `host_vars/mon.yaml` — append `filebrowser`, `dozzle`, `beszel`, `beszel-agent` to `services_configs`.
- `host_vars/infra.yaml` — append `filebrowser`, `dozzle`, `beszel-agent`.
- `host_vars/apps.yaml` — append `filebrowser`, `dozzle`, `beszel-agent`.
- `host_vars/mqtt.yaml` — append `filebrowser`, `dozzle`, `beszel-agent`.
- `host_vars/nvr.yaml` — append `filebrowser`, `dozzle`, `beszel-agent`.
- `host_vars/external-01.yaml` — append `dozzle`, `beszel-agent`.
- `vars/vault.yaml` — add `beszel_hub_pubkey` (after step 1 bootstrap). Add `beszel_websocket_token` for external-01 agent.

## Per-service detail

### Filebrowser

- Image: `filebrowser/filebrowser:{{ filebrowser_version }}`
- Volumes:
  - `/opt/knxcloud:/srv` — entire stack dir is browsable/manageable.
  - `./database:/database` — sqlite DB for filebrowser users.
  - `./config:/config` — `settings.json` if needed.
- `required_folders:` `database`, `config`
- Labels: Traefik HTTPS router on `files.${FULL_DOMAIN}`, basic-auth middleware.
- No published host port.
- First-login admin/admin → must be changed manually on each host.

### Dozzle

- Image: `amir20/dozzle:{{ dozzle_version }}`
- Volumes:
  - `/var/run/docker.sock:/var/run/docker.sock:ro`
- Env:
  - `DOZZLE_AUTH_PROVIDER=none` (Traefik handles auth)
  - `DOZZLE_LEVEL=info`
- Labels: Traefik HTTPS router on `dozzle.${FULL_DOMAIN}`, basic-auth middleware.
- No published host port.

### Beszel hub

- Image: `henrygd/beszel:{{ beszel_version }}`
- Volumes:
  - `./data:/beszel_data` — SQLite DB and SSH keys.
- `required_folders:` `data`
- Labels: Traefik HTTPS router on `beszel.${FULL_DOMAIN}` → service port 8090.
- No published host port.
- No Traefik basic-auth (built-in auth is sufficient).

### Beszel agent (local hosts)

- Image: `henrygd/beszel-agent:{{ beszel_agent_version }}`
- Network mode: `host` (per upstream recommendation, so the agent sees real interface stats).
- Env:
  - `PORT=45876`
  - `KEY={{ beszel_hub_pubkey }}` (from vault)
- Volumes:
  - `/var/run/docker.sock:/var/run/docker.sock:ro`
- No Traefik labels (agent is not HTTP).
- Published port: 45876 (required for hub → agent reach).

### Beszel agent (external-01)

Same compose file as local agents, switched by an env var:

- Env:
  - `HUB_URL=https://beszel.mon.knxcloud.io`
  - `TOKEN={{ beszel_websocket_token }}` (from vault, issued by hub UI)
- No published host port — agent dials out.

The `.env.st` template branches on `inventory_hostname == 'external-01'` to pick the right mode.

## Testing / verification

1. `just config-only <host>` for each modified host_vars to verify Jinja templating succeeds.
2. `just run-machine mon` first — confirm beszel hub UI is reachable at `https://beszel.mon.knxcloud.io` and a public key is generated.
3. Lift pubkey into vault, then `just run-machine` for the remaining local hosts. Verify each shows up as `up` in the Beszel hub dashboard within ~30s.
4. `just run-ext` for external-01 agent. Verify WebSocket-mode agent appears in hub.
5. For Filebrowser: log in to one instance, change admin password, confirm `/srv` lists `/opt/knxcloud` contents.
6. For Dozzle: confirm Traefik basic-auth prompt appears; after auth, container list is visible.
7. UFW: confirm port 45876 is open from mon's IP on each agent host.

## Risks

- **Filebrowser at `/opt/knxcloud` is powerful** — admin user can read every service's `.env`, including ones rendered from vault. Acceptable because access is gated by Traefik basic-auth + Filebrowser's own password, but worth a callout. Do not expose filebrowser routes via Cloudflare tunnel.
- **External-01 Beszel agent** depends on Beszel ≥ 0.9 WebSocket mode. If the version pinned by Renovate ever rolls back below that, the agent breaks. The version pin should track upstream.
- **Hub pubkey rotation**: if the hub's `data/` is wiped, a new keypair is generated and every agent needs the new pubkey. This is documented in `configs/beszel/README.md`.
- **Port 45876** must not be reused by anything else. Documented in this spec; not currently in use.

## Out of scope (follow-ups)

- Beszel binary agents on `pve1`/`pve2` via systemd. Will need a small Ansible role.
- Filebrowser settings provisioning (declarative user/branding config). Acceptable to leave as a manual first-login step initially.
- Dozzle agent mode (central UI + agents) — re-evaluate if per-host turns out painful.
