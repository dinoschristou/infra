# Filebrowser, Dozzle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Roll out Filebrowser and Dozzle as new Docker-compose services across the home lab, each per-host, routed via Traefik with no new host port exposure.

**Architecture:** Each service follows the existing `services` role pattern (`/configs/<svc>/docker-compose.yaml` + `.env.st`, host_vars `services_configs` entry, deployed by `just run-machine`). Both services are fronted by the existing `traefik-auth` basic-auth middleware (referenced as `traefik-auth@docker`).

**Tech Stack:** Ansible (existing `services` role), Docker Compose v2, Traefik v3 with Cloudflare DNS-01 ACME, Renovate for image version pins.

**Spec:** `docs/superpowers/specs/2026-05-31-filebrowser-dozzle-beszel-design.md`

---

## File Structure

**New files**

- `configs/filebrowser/docker-compose.yaml` — single filebrowser container.
- `configs/filebrowser/.env.st` — Jinja template, renders `FULL_DOMAIN`.
- `configs/dozzle/docker-compose.yaml` — single dozzle container reading `/var/run/docker.sock`.
- `configs/dozzle/.env.st` — Jinja template, renders `FULL_DOMAIN`.

**Modified files**

- `group_vars/all.yaml` — two new Renovate-tracked version vars.
- `host_vars/mon.yaml`, `host_vars/infra.yaml`, `host_vars/apps.yaml`, `host_vars/mqtt.yaml`, `host_vars/nvr.yaml` — append two entries to `services_configs`.
- `host_vars/external-01.yaml` — append one entry (no filebrowser).

The `services` role itself is unchanged.

---

### Task 1: Add image version pins to group_vars/all.yaml

**Files:**
- Modify: `group_vars/all.yaml` (insert near the other `# renovate:` blocks, around line 95)

- [ ] **Step 1: Look up the current latest tags**

Run:
```bash
curl -s "https://hub.docker.com/v2/repositories/filebrowser/filebrowser/tags?page_size=5&ordering=last_updated" | jq -r '.results[].name' | head
curl -s "https://hub.docker.com/v2/repositories/amir20/dozzle/tags?page_size=5&ordering=last_updated" | jq -r '.results[].name' | head
```
Expected: prints recent semver tags. Pick the latest non-prerelease for each (e.g. `v2.31.2`, `v8.13.0`).

- [ ] **Step 2: Add the two pins to `group_vars/all.yaml`**

After the `homebridge_version:` line (~line 94), insert:

```yaml
# renovate: datasource=docker depName=filebrowser/filebrowser
filebrowser_version: "v2.31.2"
# renovate: datasource=docker depName=amir20/dozzle
dozzle_version: "v8.13.0"
```

Use the actual tag strings printed in Step 1, not the placeholders above.

- [ ] **Step 3: Verify the file still parses**

Run:
```bash
ansible-inventory -i inventory/hosts.yaml --host mon | jq .filebrowser_version
```
Expected: prints the version string you set.

- [ ] **Step 4: Commit**

```bash
git add group_vars/all.yaml
git commit -m "all: pin filebrowser and dozzle image versions"
```

---

### Task 2: Create the Filebrowser compose stack

**Files:**
- Create: `configs/filebrowser/docker-compose.yaml`
- Create: `configs/filebrowser/.env.st`

- [ ] **Step 1: Write `configs/filebrowser/.env.st`**

```jinja
FULL_DOMAIN={{ full_domain }}
TZ={{ default_timezone }}
```

- [ ] **Step 2: Write `configs/filebrowser/docker-compose.yaml`**

```yaml
services:
  filebrowser:
    image: filebrowser/filebrowser:${FILEBROWSER_VERSION:-v2.31.2}
    container_name: filebrowser
    restart: unless-stopped
    env_file:
      - .env
    environment:
      - TZ=${TZ}
      - PUID=1000
      - PGID=1000
    networks:
      - proxy
    volumes:
      - /opt/knxcloud:/srv
      - ./database:/database
      - ./config:/config
    user: "1000:1000"
    command:
      - --database=/database/filebrowser.db
      - --root=/srv
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.filebrowser.rule=Host(`files.${FULL_DOMAIN}`)"
      - "traefik.http.routers.filebrowser.entrypoints=https"
      - "traefik.http.routers.filebrowser.tls=true"
      - "traefik.http.routers.filebrowser.middlewares=traefik-auth@docker"
      - "traefik.http.services.filebrowser.loadbalancer.server.port=80"

networks:
  proxy:
    external: true
```

- [ ] **Step 3: Lint the compose file**

Run:
```bash
docker compose -f configs/filebrowser/docker-compose.yaml config -q
```
Expected: no output (valid compose).

- [ ] **Step 4: Commit**

```bash
git add configs/filebrowser/
git commit -m "filebrowser: add docker-compose stack"
```

---

### Task 3: Create the Dozzle compose stack

**Files:**
- Create: `configs/dozzle/docker-compose.yaml`
- Create: `configs/dozzle/.env.st`

- [ ] **Step 1: Write `configs/dozzle/.env.st`**

```jinja
FULL_DOMAIN={{ full_domain }}
TZ={{ default_timezone }}
```

- [ ] **Step 2: Write `configs/dozzle/docker-compose.yaml`**

```yaml
services:
  dozzle:
    image: amir20/dozzle:${DOZZLE_VERSION:-v8.13.0}
    container_name: dozzle
    restart: unless-stopped
    env_file:
      - .env
    environment:
      - TZ=${TZ}
      - DOZZLE_AUTH_PROVIDER=none
      - DOZZLE_LEVEL=info
    networks:
      - proxy
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.dozzle.rule=Host(`dozzle.${FULL_DOMAIN}`)"
      - "traefik.http.routers.dozzle.entrypoints=https"
      - "traefik.http.routers.dozzle.tls=true"
      - "traefik.http.routers.dozzle.middlewares=traefik-auth@docker"
      - "traefik.http.services.dozzle.loadbalancer.server.port=8080"

networks:
  proxy:
    external: true
```

- [ ] **Step 3: Lint the compose file**

Run:
```bash
docker compose -f configs/dozzle/docker-compose.yaml config -q
```
Expected: no output.

- [ ] **Step 4: Commit**

```bash
git add configs/dozzle/
git commit -m "dozzle: add docker-compose stack"
```

---

### Task 4: Wire host_vars/mon.yaml (canary host)

**Files:**
- Modify: `host_vars/mon.yaml`

- [ ] **Step 1: Append two services to `services_configs`**

After the `uptimekuma` block (currently the last entry, ending at line 16), append:

```yaml
  - name: filebrowser
    required_folders:
      - database
      - config
  - name: dozzle
```

- [ ] **Step 2: Verify `mon.yaml` still parses**

Run:
```bash
ansible-inventory -i inventory/hosts.yaml --host mon \
  | jq '.services_configs[].name'
```
Expected: list ends with `"filebrowser"`, `"dozzle"`.

- [ ] **Step 3: Dry-run template rendering**

Run:
```bash
just config-only mon
```
Expected: playbook runs to completion. Verify on `mon`:

```bash
ssh mon "ls /opt/knxcloud/filebrowser /opt/knxcloud/dozzle"
```
Expected: both directories exist; `filebrowser/` contains `database/`, `config/`, `docker-compose.yaml`, `.env`.

- [ ] **Step 4: Commit**

```bash
git add host_vars/mon.yaml
git commit -m "mon: enable filebrowser and dozzle"
```

---

### Task 5: Deploy to mon and verify the two services come up

**Files:** none (deploy + verify only)

- [ ] **Step 1: Deploy**

Run:
```bash
just run-machine mon
```
Expected: ends with no failed tasks. Two new containers running.

- [ ] **Step 2: Container check**

Run:
```bash
ssh mon "docker ps --format '{{.Names}} {{.Status}}' | grep -E 'filebrowser|dozzle'"
```
Expected: two lines, each `Up …`.

- [ ] **Step 3: Filebrowser HTTPS reachability**

From your workstation (Pi-hole DNS must resolve `files.mon.knxcloud.io`):

```bash
curl -sk -o /dev/null -w "%{http_code}\n" https://files.mon.knxcloud.io
```
Expected: `401` (Traefik basic-auth challenge).

Then with credentials (your existing Traefik dashboard creds):

```bash
curl -sk -u 'YOUR_TRAEFIK_USER:YOUR_TRAEFIK_PASS' \
  -o /dev/null -w "%{http_code}\n" https://files.mon.knxcloud.io
```
Expected: `200`.

- [ ] **Step 4: Dozzle HTTPS reachability**

```bash
curl -sk -o /dev/null -w "%{http_code}\n" https://dozzle.mon.knxcloud.io
curl -sk -u 'YOUR_TRAEFIK_USER:YOUR_TRAEFIK_PASS' \
  -o /dev/null -w "%{http_code}\n" https://dozzle.mon.knxcloud.io
```
Expected: `401` then `200`.

- [ ] **Step 5: Filebrowser first-login (manual, one-time)**

Open `https://files.mon.knxcloud.io`:
1. Log in with `admin` / `admin`.
2. Immediately change the admin password in user settings.

- [ ] **Step 6: No commit needed (deploy-only task). Record outcomes in your notes.**

---

### Task 6: Roll out to infra, apps, mqtt, and nvr

**Files:**
- Modify: `host_vars/infra.yaml`
- Modify: `host_vars/apps.yaml`
- Modify: `host_vars/mqtt.yaml`
- Modify: `host_vars/nvr.yaml`

- [ ] **Step 1: Append the same two services to each host_vars file**

For each of `host_vars/infra.yaml`, `host_vars/apps.yaml`, `host_vars/mqtt.yaml`, `host_vars/nvr.yaml`, append this block to the end of the `services_configs` list:

```yaml
  - name: filebrowser
    required_folders:
      - database
      - config
  - name: dozzle
```

- [ ] **Step 2: Parse-check all four files**

Run:
```bash
for h in infra apps mqtt nvr; do
  echo "=== $h ==="
  ansible-inventory -i inventory/hosts.yaml --host "$h" \
    | jq -r '.services_configs[-2:][].name'
done
```
Expected: each host prints `filebrowser`, `dozzle`.

- [ ] **Step 3: Deploy one host at a time and verify each**

For each host in `infra apps mqtt nvr`:

```bash
just run-machine infra   # then apps, mqtt, nvr
ssh infra "docker ps --format '{{.Names}}' | grep -E 'filebrowser|dozzle' | sort"
```
Expected per host: two container names listed.

Then check the two Traefik routes (substituting hostname):

```bash
for svc in files dozzle; do
  curl -sk -o /dev/null -w "%{http_code} $svc.infra\n" https://$svc.infra.knxcloud.io
done
```
Expected: `401`, `401` (auth challenge for both).

- [ ] **Step 4: Filebrowser first-login per host**

For each of `files.infra.knxcloud.io`, `files.apps.knxcloud.io`, `files.mqtt.knxcloud.io`, `files.nvr.knxcloud.io`: log in with `admin` / `admin` and change the password.

- [ ] **Step 5: Commit the host_vars changes (single commit)**

```bash
git add host_vars/infra.yaml host_vars/apps.yaml host_vars/mqtt.yaml host_vars/nvr.yaml
git commit -m "infra/apps/mqtt/nvr: enable filebrowser and dozzle"
```

---

### Task 7: Roll out Dozzle to external-01

**Files:**
- Modify: `host_vars/external-01.yaml`

- [ ] **Step 1: Append dozzle (no filebrowser on external-01)**

Append to the `services_configs` list in `host_vars/external-01.yaml`:

```yaml
  - name: dozzle
```

- [ ] **Step 2: Parse-check**

Run:
```bash
ansible-inventory -i inventory/hosts.yaml --host external-01 \
  | jq -r '.services_configs[-1:][].name'
```
Expected: `dozzle`.

- [ ] **Step 3: Deploy**

Run:
```bash
just run-ext
```
Expected: completes without failed tasks.

- [ ] **Step 4: Container check**

Run:
```bash
ssh external-01 "docker ps --format '{{.Names}}' | grep dozzle"
```
Expected: `dozzle`.

- [ ] **Step 5: HTTPS reachability**

On external-01 the `FULL_DOMAIN` is `dinos.sh`, so the route is at the apex domain — `dozzle.dinos.sh`:

```bash
curl -sk -o /dev/null -w "%{http_code}\n" https://dozzle.dinos.sh
curl -sk -u 'YOUR_TRAEFIK_USER:YOUR_TRAEFIK_PASS' \
  -o /dev/null -w "%{http_code}\n" https://dozzle.dinos.sh
```
Expected: `401`, `200`.

- [ ] **Step 6: Commit**

```bash
git add host_vars/external-01.yaml
git commit -m "external-01: enable dozzle"
```

---

### Task 8: Cross-host smoke test and wrap-up

**Files:** none (verification only)

- [ ] **Step 1: Confirm every expected route returns the expected status**

Run from your workstation:

```bash
for host in mon infra apps mqtt nvr; do
  for svc in files dozzle; do
    code=$(curl -sk -o /dev/null -w "%{http_code}" https://$svc.$host.knxcloud.io)
    echo "$svc.$host.knxcloud.io -> $code (expected 401)"
  done
done

code=$(curl -sk -o /dev/null -w "%{http_code}" https://dozzle.dinos.sh)
echo "dozzle.dinos.sh -> $code (expected 401)"
```
Expected: every line is `401` (Traefik basic-auth challenge).

- [ ] **Step 2: Confirm no host port collisions were introduced**

Run on every host:

```bash
for h in mon infra apps mqtt nvr external-01; do
  echo "=== $h ==="
  ssh $h "ss -tlnp 2>/dev/null | awk 'NR>1 {print \$4}' | sort -u | grep -E ':(80|443|8080)\$' || echo no-conflicts"
done
```
Expected: each host shows `:80` and `:443` (Traefik) only. Filebrowser (port 80 inside the container) and Dozzle (8080 inside the container) should not appear on the host's listening sockets.

- [ ] **Step 3: Final commit (docs touch-up if needed)**

If no further code changes are required, this task ends with no commit. Otherwise, fix anything found and commit.

---

## Rollback

If a host's deployment breaks:

```bash
ssh <host> "cd /opt/knxcloud/<svc> && docker compose down"
```

Revert the host_vars change with `git revert <commit>` and re-run `just run-machine <host>` to restore the prior state. Filebrowser and Dozzle are additive — none of them depend on or modify other services, so removing them is safe.

## Notes for the implementer

- Filebrowser at `/opt/knxcloud:/srv` exposes every service's `.env` (including secrets rendered from vault). Do not publish filebrowser routes through Cloudflare. The local-only `knxcloud.io` domain handles this correctly today, which is why filebrowser is omitted from external-01.
