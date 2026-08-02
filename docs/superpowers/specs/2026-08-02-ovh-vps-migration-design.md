# Design: Migrate `external-01` → OVH VPS `vps-01`

**Date:** 2026-08-02
**Status:** Approved design, pending implementation plan
**Scope:** Replace the local Proxmox VM `external-01` (public `dinos.sh` services, currently
served via Cloudflare Tunnel) with a public-IP OVH VPS `vps-01`, integrated into the existing
Ansible repo. Container-based, security-hardened, on Tailscale but isolated from other nodes.

---

## 1. Overview & Identity

`external-01` today is a *local* Proxmox VM (`is_local_vm: true`) that reaches the public
internet through a Cloudflare Tunnel (`cloudflared`) — it has **no direct public exposure**.
Moving to an OVH VPS with a **real public IP** changes the fundamental network model.

- **New host:** `vps-01` in the `cloud` inventory group; `external-01` removed after decommission.
- **New `host_vars/vps-01.yaml`:** `is_local_vm: false`, `hostname_root: dinos.sh`,
  `full_domain: dinos.sh`, `acme_provider: cloudflare`, `cloudflare_proxied: true`,
  `app_folder_root: /opt/stacks`.
- **Specs:** 12 GB RAM / 6 vCPU / 100 GB disk. Comfortable for Authentik (~2 GB baseline) + apps.
- **OS:** whatever OVH provisioned. **First provisioning task verifies it is apt/Debian-family**
  before relying on existing roles; adapt if not.

### Service changes

| Action | Services |
|---|---|
| **Keep** | traefik, littlelink *(public)*, freshrss, wallabag, monitoring-client, dozzle |
| **Add** | authentik (postgres + redis + server + worker), docker-socket-proxy |
| **Drop** | cloudflared, crowdsec, karakeep, **linkwarden** |

Rationale for drops: no tunnel needed (direct exposure); crowdsec not wanted; karakeep not used;
fully migrated off Linkwarden onto Wallabag.

---

## 2. Network & Exposure

```
Internet → Cloudflare (proxied / orange-cloud) → :443 Traefik → apps
                                                 :80  Traefik → 301 https
```

- **Exposure model:** direct Traefik on 80/443, Cloudflare proxied DNS in front.
- **Ingress firewall (nftables or ufw):** default-deny inbound. Allow **80/443 only from
  Cloudflare's published IP ranges** (v4 + v6). A deploy task fetches
  `https://www.cloudflare.com/ips-v4` and `ips-v6` and renders the allowlist so the origin
  cannot be hit directly by scanners. Refreshed on each deploy (optionally a periodic timer).
- **TLS:** Traefik keeps the existing **Cloudflare DNS-01** ACME challenge — no inbound needed
  for issuance; port 80 exists only for HTTPS redirect.
- **DNS cutover:** records change from tunnel CNAMEs to **proxied A/AAAA** pointing at the VPS IP.
  `cloudflared` is removed.

---

## 3. Management Access (SSH)

Dual-path: primary over Tailscale, locked-down public break-glass.

- **Primary:** SSH + Ansible over **Tailscale** (`tailscale0`, `100.x`), key-only.
- **Break-glass:** public SSH on a **custom port**, key-only, root login disabled,
  `fail2ban` + firewall rate-limit. Survives Tailscale being down.
- **Inventory:** `ansible_host: <tailscale-ip>`, `ansible_port: <custom-port>`.

### Bootstrap ordering (the box starts bare)

1. Initial connect via OVH default public SSH → create admin user, install SSH keys.
2. Install + join Tailscale; harden `sshd` (custom port, key-only, no root, no password).
3. Configure firewall (deny-by-default, CF ranges for 80/443, break-glass SSH port).
4. All subsequent Ansible runs target the **Tailscale IP**; public port is fallback only.

---

## 4. Tailscale Isolation (`tag:vps-edge`)

The VPS is on the tailnet but **cannot initiate connections** to any other node. Enforced by a
tagged ACL. Intended policy:

```jsonc
{
  "tagOwners": { "tag:vps-edge": ["your-user"] },
  "acls": [
    // VPS initiates to NOTHING on the tailnet (covered by default-deny egress).
    // mon pulls metrics from the VPS (node-exporter / cAdvisor ports):
    { "action": "accept", "src": ["tag:mon"],        "dst": ["tag:vps-edge:9100,8080"] },
    // admin device reaches VPS SSH:
    { "action": "accept", "src": ["your-admin-dev"], "dst": ["tag:vps-edge:22"] }
  ]
}
```

- **Logs stay local:** no `vps-01 → mon:loki` egress. Central Loki/Grafana will NOT contain
  VPS logs — by design. Local observability via **dozzle + journald** only.
- **Metrics preserved:** `mon → vps-01` is a *pull*, so it needs no VPS egress.
- ⚠️ **Risk to verify in the plan:** confirm `monitoring-client` is **scrape-only** (pull). If any
  part pushes (e.g. to pushgateway), that requires egress and breaks isolation — switch it to
  scrape-only or drop that component before cutover.

---

## 5. Container Security

- **docker-socket-proxy** (read-only, minimal API surface) in front of anything needing the
  Docker socket. With crowdsec dropped, the only consumer is **dozzle**. No container mounts
  `/var/run/docker.sock` directly.
- **Per-service hardening defaults:** `security_opt: [no-new-privileges:true]`,
  `cap_drop: [ALL]` + minimal add-back, non-root `user:` where the image allows, `read_only`
  rootfs + `tmpfs` where feasible, memory/CPU limits, back-end networks marked `internal: true`
  (only Traefik joins the external `proxy` network).
- **OS:** `unattended-upgrades` for security patches; images pinned + Renovate-managed.

---

## 6. Secrets — Hardened `.env`

Keep the ansible-vault → rendered `.env` model. `.env` is acceptable here because the source of
truth (`vars/vault.yaml`) is encrypted in git and the plaintext only ever exists on the host.
The gap to close is on-disk permissions:

- Rendered `.env` files: **`0600`**, owned by root (or the service user).
- Service directories: **`0700`**.
- Audit that nothing under `/opt/stacks/**` is world-readable; enforce perms in the role.
- Accepted residual risk: once a value is a container env var it is visible via `docker inspect`
  and `/proc/<pid>/environ` to root — inherent to Docker env, mitigated by the host hardening in
  §5 (socket proxy, least-priv, firewall, no public SSH). File-based Docker secrets were
  considered and deferred (not adopted) as an optional future upgrade for DB / `AUTHENTIK_SECRET_KEY`.

---

## 7. Authentik SSO

Authentik runs **locally on the VPS** (self-contained edge), reusing the existing
`configs/authentik/` compose (postgres 16 + redis + server + worker), published at
**`auth.dinos.sh`**. Forward-auth uses Authentik's **embedded outpost** (no extra container) via
a reusable Traefik middleware attached per-router with labels.

| Service | Auth method |
|---|---|
| freshrss | Traefik **forward-auth** (Authentik proxy provider) |
| wallabag | Traefik **forward-auth** |
| dozzle | Traefik **forward-auth** |
| traefik dashboard | **forward-auth** (replaces basic auth) |
| authentik | Public (`auth.dinos.sh`) |
| littlelink | Public, no auth (public link-in-bio page) |

A single `authentik-forwardauth` middleware is defined once (pointing at the embedded outpost
endpoint) and referenced by each protected router.

---

## 8. Data Migration (mixed; hard cutover)

| Service | Plan |
|---|---|
| wallabag | **Migrate**: DB dump + `images/`, `data/` volumes → restore on VPS, verify login/counts |
| freshrss | **Migrate**: DB → restore on VPS, verify feeds (OPML re-import is the fallback) |
| littlelink | **Redeploy** from config (no persistent state) |
| linkwarden | **Dropped** — no migration |
| karakeep | **Dropped** — no migration |

### Backups

- **OVH provider-side** automated VPS backup/snapshot enabled.
- **Nightly local `pg_dump`** (Authentik DB, Wallabag/FreshRSS DBs as applicable) into a volume,
  so the OVH snapshot captures consistent logical dumps. Retain a short rolling window on-disk.

---

## 9. Log Rotation & Disk Hygiene

100 GB is finite; unattended log growth is the primary failure mode. Layered caps:

- **Docker daemon default** (`/etc/docker/daemon.json`): `json-file` driver with
  `max-size=10m`, `max-file=3` — applies to every container.
- **Traefik access logs** (`logs/` volume): `logrotate` with `copytruncate`, daily, compressed,
  bounded retention.
- **journald cap:** `SystemMaxUse` bounded (e.g. 500 MB) in `journald.conf`.
- **App data growth** (Wallabag images, FreshRSS): covered by the existing per-instance disk
  alert scraped by `mon`, which fires before the disk fills.
- Optional weekly `docker system prune -f` (dangling images/build cache) via systemd timer.

---

## 10. Cutover (hard)

1. Lower Cloudflare DNS **TTL** on affected records ~24 h ahead.
2. Provision + harden `vps-01`; deploy the full stack; verify each app via a temporary test
   hostname (old VM still serving live traffic).
3. Configure Authentik providers/apps; verify SSO end-to-end (native + forward-auth).
4. **Maintenance window:** stop apps on old VM → final data sync (Wallabag, FreshRSS) → restore
   → verify.
5. Flip Cloudflare records (tunnel CNAME → proxied A/AAAA at VPS IP); confirm `cloudflared` gone.
6. Smoke-test all `dinos.sh` services → decommission old `external-01` (remove from inventory)
   the same day. Rollback = restore from backup (accepted: slower than a parallel fallback).

---

## 11. Repo Integration & Testing

### New / changed

- `inventory/hosts.yaml`: add `vps-01` to `cloud`; remove `external-01` after decommission.
- `host_vars/vps-01.yaml`: service list, exposure/domain vars, `is_local_vm: false`.
- Tailscale provisioning (role or tasks) + `tag:vps-edge` join.
- `docker-socket-proxy` config; `dozzle` repointed at the proxy.
- `authentik` wired into `services_configs`; forward-auth middleware in Traefik.
- Cloudflare-IP firewall task; hardened-`.env` perms enforcement; log-rotation config;
  nightly `pg_dump` timer.

### Reuse

- Existing `services` role, Traefik role, `monitoring-client`.

### Test / verification checklist

- Firewall: 443 reachable only from CF ranges; direct origin hit refused.
- SSH: reachable via Tailscale; break-glass port works; password + root login refused.
- Each app: reachable and SSO enforced (littlelink public).
- Metrics: `mon` scrape succeeds; VPS→tailnet egress **blocked** (proven with a denied test).
- Backup: `pg_dump` produces valid dumps; restore dry-run succeeds.
- Disk: docker/journald/traefik log caps in place.

---

## 12. Open Items for the Plan

- Confirm `monitoring-client` is scrape-only (see §4 risk).
- Confirm OVH OS is apt-based at provisioning; adapt roles if not.
- Choose exact break-glass SSH port and admin device identity for the ACL.
