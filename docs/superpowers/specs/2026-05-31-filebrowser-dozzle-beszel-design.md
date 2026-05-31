# Filebrowser, Dozzle, Beszel — Design

**Date:** 2026-05-31
**Scope:** Add three new self-hosted ops services to the home lab: Filebrowser (file management), Dozzle (Docker logs), Beszel (server monitoring). All deployed per-host and routed via Traefik with the existing `services` role.

## Goals

- File management UI on every local Docker VM, rooted at `/opt/knxcloud`.
- Per-host Docker log viewer (Dozzle) so logs are inspected in the context of a single host.
- Per-host server monitor (Beszel) — each VM runs its own hub + a co-located agent, showing only its own metrics.
- All three sit behind Traefik with Cloudflare-issued certs. Filebrowser and Dozzle are fronted by the existing Traefik basic-auth middleware; Beszel uses its built-in auth.
- Avoid host-port collisions. Prefer Traefik-only routing with no published host ports unless required by the protocol.

## Non-goals

- Central Beszel hub / cross-host monitoring aggregation. Rejected in favour of the per-host simplicity that matches the Dozzle and Filebrowser deployments.
- Beszel agents on `pve1` / `pve2` Proxmox hypervisors. Deferred — Proxmox hosts are not Docker hosts and need a binary/systemd install plus an Ansible role.
- Filebrowser on `external-01` (cloud server). No clear need; would require a public route for what is essentially admin tooling.
- Migrating away from Portainer or Uptime Kuma. New services are additive.

## Architecture

### Deployment matrix

| Service | mon | infra | apps | mqtt | nvr | external-01 |
|---|---|---|---|---|---|---|
| filebrowser | ✓ | ✓ | ✓ | ✓ | ✓ | — |
| dozzle | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| beszel (hub + agent pair) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |

Beszel is deployed as a hub container plus an agent container on the same host, joined by a private Docker network (`beszel_internal`). The hub points at the agent by container name; the agent never exposes a port to the host.

### Port mapping

The existing `uptimekuma` config sets the precedent: no host port, route everything through Traefik. We follow that throughout.

| Service | Container port | Host port | Traefik route |
|---|---|---|---|
| filebrowser | 80 | none | `files.<host>.knxcloud.io` |
| dozzle | 8080 | none | `dozzle.<host>.knxcloud.io` (local) / `dozzle.dinos.sh` (external-01) |
| beszel hub | 8090 | none | `beszel.<host>.knxcloud.io` (local) / `beszel.dinos.sh` (external-01) |
| beszel agent | 45876 | none — reachable only on `beszel_internal` Docker network | n/a |

**No new host ports are introduced.** All cross-container traffic stays on Docker networks.

### Auth model

Filebrowser and Dozzle are fronted by the **Traefik basic-auth middleware** that already exists for the Traefik dashboard:

```yaml
labels:
  - "traefik.http.routers.<svc>.middlewares=traefik-auth@docker"
```

This re-uses `TRAEFIK_DASHBOARD_CREDENTIALS` from `.env` — no second credential set to manage. Filebrowser's own user database is still used for actual file-level permissions (single admin user, default password rotated on first login). Dozzle runs with `DOZZLE_AUTH_PROVIDER=none` because Traefik gates access.

Beszel has built-in auth (per-instance admin account, email/password) and does not need Traefik basic-auth on top. Each host's Beszel instance has its own independent admin account.

### Beszel hub ↔ agent trust

On first startup, the Beszel hub generates an SSH key pair at `/beszel_data/id_ed25519`. The pubkey must be passed to the agent via the `KEY` env var so the hub can authenticate to it.

We pre-generate a single Ed25519 keypair locally and reuse it across all hosts:

- Private key stored in `vars/vault.yaml` as `beszel_hub_privkey` (multi-line vaulted string).
- Public key stored in `vars/vault.yaml` as `beszel_hub_pubkey`.

The hub's compose template writes the private key to `./data/id_ed25519` before the container starts (via a `pre_tasks` step in the `services` role, or simply as a templated file in `required_folders` / `touch_files`). The agent reads `KEY={{ beszel_hub_pubkey }}` directly from its `.env`.

Reusing the keypair across hosts is safe because each host's agent listens only on the private `beszel_internal` Docker network — there is no LAN exposure, no cross-host trust, and the pubkey gates access to a metrics-only endpoint on a non-routed network.

This removes the staged bootstrap step from the previous (hub+agents) design: every host can be deployed in any order.

## Files added

```
configs/filebrowser/
  docker-compose.yaml
  .env.st
configs/dozzle/
  docker-compose.yaml
  .env.st
configs/beszel/
  docker-compose.yaml      # hub + agent on a private network, single compose stack
  .env.st
  id_ed25519.j2            # templated from vault (or written via touch_files)
docs/superpowers/specs/2026-05-31-filebrowser-dozzle-beszel-design.md
```

There is no separate `configs/beszel-agent/` — the agent is part of the Beszel stack on every host.

## Files modified

- `group_vars/all.yaml` — add four Renovate-managed version pins:
  - `filebrowser_version` (datasource: docker, depName: filebrowser/filebrowser)
  - `dozzle_version` (datasource: docker, depName: amir20/dozzle)
  - `beszel_version` (datasource: docker, depName: henrygd/beszel)
  - `beszel_agent_version` (datasource: docker, depName: henrygd/beszel-agent)
- `host_vars/mon.yaml` — append `filebrowser`, `dozzle`, `beszel` to `services_configs`.
- `host_vars/infra.yaml` — append `filebrowser`, `dozzle`, `beszel`.
- `host_vars/apps.yaml` — append `filebrowser`, `dozzle`, `beszel`.
- `host_vars/mqtt.yaml` — append `filebrowser`, `dozzle`, `beszel`.
- `host_vars/nvr.yaml` — append `filebrowser`, `dozzle`, `beszel`.
- `host_vars/external-01.yaml` — append `dozzle`, `beszel`.
- `vars/vault.yaml` — add `beszel_hub_privkey` and `beszel_hub_pubkey`.

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

### Beszel (hub + agent stack)

Single compose file with two services on a private network.

**Hub service:**

- Image: `henrygd/beszel:{{ beszel_version }}`
- Volumes:
  - `./data:/beszel_data` — SQLite DB and SSH key (private key pre-templated from vault).
- Networks: `proxy` (for Traefik), `beszel_internal` (for talking to the agent).
- Labels: Traefik HTTPS router on `beszel.${FULL_DOMAIN}` → service port 8090. No basic-auth middleware (built-in auth).
- No published host port.
- After first start: add a System entry in the Beszel UI pointing at host `beszel-agent` port `45876`.

**Agent service:**

- Image: `henrygd/beszel-agent:{{ beszel_agent_version }}`
- Container name: `beszel-agent` (so the hub can resolve it by DNS on `beszel_internal`).
- Networks: `beszel_internal` only — no `proxy`, no host networking, no published ports.
- Env:
  - `PORT=45876`
  - `KEY={{ beszel_hub_pubkey }}` (from vault, via `.env`)
- Volumes:
  - `/var/run/docker.sock:/var/run/docker.sock:ro` — for Docker container metrics.
  - `/:/hostfs:ro` — recommended by upstream for accurate host disk/CPU stats.

`required_folders:` `data`

`.env.st` is the same across every host — no per-host branching.

## Testing / verification

1. Locally generate an Ed25519 keypair (`ssh-keygen -t ed25519 -N "" -f /tmp/beszel`), add private and public to `vars/vault.yaml`, encrypt.
2. `just config-only <host>` for each modified host_vars to verify Jinja templating succeeds.
3. `just run-machine mon` — confirm:
   - `https://files.mon.knxcloud.io` prompts for Traefik basic-auth then shows Filebrowser login.
   - `https://dozzle.mon.knxcloud.io` prompts for Traefik basic-auth then shows the Dozzle container list.
   - `https://beszel.mon.knxcloud.io` shows Beszel first-run admin setup; after setup, adding a System pointing at `beszel-agent:45876` reports `up` within ~30s.
4. Repeat per host with `just run-machine <host>`; `just run-ext` for external-01.
5. Confirm no UFW changes were needed — none of the new services expose host ports.

## Risks

- **Filebrowser at `/opt/knxcloud` is powerful** — admin user can read every service's `.env`, including ones rendered from vault. Acceptable because access is gated by Traefik basic-auth + Filebrowser's own password, but worth a callout. Do not expose filebrowser routes via Cloudflare tunnel.
- **Shared Beszel keypair**: stored in vault and reused across hosts. Compromise of the vault is a much bigger issue already, and the keypair only protects metrics endpoints on private Docker networks. Acceptable trade for the simpler per-host model.
- **Per-host Beszel admin accounts**: each VM has its own admin user; no SSO. Tolerable for six hosts.
- **No central view**: looking at trends across hosts requires opening six tabs. If this becomes painful, future work can promote one Beszel instance (likely `mon`) to be the hub and have the others register as agents — the agent containers we deploy now are already capable.

## Out of scope (follow-ups)

- Beszel binary agents on `pve1`/`pve2` via systemd. Will need a small Ansible role.
- Filebrowser settings provisioning (declarative user/branding config). Acceptable to leave as a manual first-login step initially.
- Dozzle agent mode (central UI + agents) — re-evaluate if per-host turns out painful.
- Consolidating Beszel to a hub + agent model if multi-host correlation becomes needed.
