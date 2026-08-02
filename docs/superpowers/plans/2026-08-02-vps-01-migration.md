# OVH `vps-01` Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the local Proxmox VM `external-01` (public `dinos.sh` services behind a Cloudflare Tunnel) with a hardened, container-based OVH VPS `vps-01` that is directly exposed behind Cloudflare's proxy, joined to Tailscale but isolated from other tailnet nodes, and fronts all non-public apps with Authentik SSO.

**Architecture:** Ansible-managed Debian/Ubuntu host in the `cloud` inventory group. Traefik terminates TLS on 80/443, reachable only from Cloudflare IP ranges (host firewall) with Cloudflare DNS-01 ACME. Docker workloads are hardened (socket-proxy, least-privilege). Authentik (local Postgres+Redis+server+worker) provides OIDC/forward-auth. Management is via Tailscale (primary) plus a locked-down public break-glass SSH port.

**Isolation strategy (Option 2 — dedicated configs):** Because `configs/` is shared across all hosts and Traefik/Dozzle/monitoring-client run on all 6, `vps-01` uses **dedicated `-vps` config directories** (`traefik-vps`, `dozzle-vps`, `monitoring-client-vps`) plus new configs (`authentik`, `docker-socket-proxy`). The shared `configs/traefik`, `configs/dozzle`, `configs/monitoring-client` are **left untouched**, so the 5 production hosts are unaffected. `freshrss`/`wallabag`/`littlelink` are external-01-only, so their configs are edited in place. No changes to the `services` role.

**Tech Stack:** Ansible, Docker Compose (`community.docker.docker_compose_v2`), Traefik v3, Authentik, Tailscale, ufw, Cloudflare (proxied DNS + DNS-01), OVH provider backups + local `pg_dump`.

## Global Constraints

- Target host: `vps-01`, OVH, 12 GB RAM / 6 vCPU / 100 GB disk. Public IPv4 (+IPv6 if provided).
- `app_folder_root: /opt/stacks`; domain `dinos.sh`; `acme_provider: cloudflare`; `cloudflare_proxied: true`; `is_local_vm: false`.
- Exposure: inbound **80/443 only from Cloudflare IP ranges**; break-glass SSH on custom port `4322`; everything else default-deny. Tailscale interface allows only `mon → 9100,8082` and `admin-device → SSH`.
- Tailscale tag: `tag:vps-edge`, **no egress** to other tailnet nodes (local logs only; metrics are pull).
- Secrets: ansible-vault source of truth; rendered `.env` files `0600`; service dirs on vps-01 tightened to `0700` (via the hardening role, NOT the shared services role).
- **Do NOT modify** shared configs `configs/traefik`, `configs/dozzle`, `configs/monitoring-client`, or the `services` role — they are used by 5 production hosts. vps-01 gets `-vps` variants instead.
- Drop from vps-01: `cloudflared`, `crowdsec`, `karakeep`, `linkwarden`, `promtail`. Add: `authentik`, `docker-socket-proxy`.
- SSO: freshrss/wallabag/dozzle/traefik-dashboard via Authentik forward-auth; littlelink public.
- All secrets committed to git MUST be inside the ansible-vault-encrypted `vars/vault.yaml`.
- Deploy with `ansible-playbook -i inventory/hosts.yaml site.yaml --limit vps-01` (`just run-machine vps-01`).

---

## File Structure

**New files**
- `roles/tailscale/tasks/main.yaml`, `roles/tailscale/defaults/main.yaml` — join tailnet as `tag:vps-edge`, no route acceptance.
- `roles/hardening/tasks/main.yaml`, `roles/hardening/handlers/main.yaml`, `roles/hardening/templates/{jail.local.j2,logrotate-traefik.j2,pg-backup.sh.j2,pg-backup.service.j2,pg-backup.timer.j2}` — public-host firewall, sshd, fail2ban, log rotation, 0700 dirs, pg_dump timer. Runs only on vps-01.
- `configs/docker-socket-proxy/{docker-compose.yaml,.env.st}` — read-only socket proxy (vps-only).
- `configs/traefik-vps/{docker-compose.yaml,traefik.yml.j2,config.yml.j2,.env.st}` — hardened Traefik: socket-proxy provider, no crowdsec, Authentik dashboard middleware + `authentik@file` middleware.
- `configs/dozzle-vps/{docker-compose.yaml,.env.st}` — Dozzle via socket-proxy + Authentik middleware.
- `configs/monitoring-client-vps/{docker-compose.yaml,.env.st,...}` — node-exporter + cadvisor only (no promtail).
- `host_vars/vps-01.yaml` — service list + host vars.

**Modified files (safe — not shared with the 5 production hosts)**
- `inventory/hosts.yaml` — add `vps-01` to `cloud`; remove `external-01` at cutover.
- `group_vars/all.yaml` — add `docker_log_max_size`/`docker_log_max_file`/`journald_system_max_use`/`mon_tailscale_ip` defaults.
- `site.yaml` — add a dedicated `vps-01` play; scope the legacy cloud play to `external-01`.
- `roles/docker/tasks/main.yaml` (+handler) — `/etc/docker/daemon.json` log caps. *(shared role; change is behavior-preserving via defaults — see Task 5 note.)*
- `roles/base/tasks/main.yaml` (+handler) — journald cap. *(shared role; behavior-preserving.)*
- `configs/freshrss/docker-compose.yaml`, `configs/wallabag/docker-compose.yaml` — add `authentik@file` middleware label (external-01-only services).
- `configs/authentik/.env.st` — bind vault secrets.
- `vars/vault.yaml` — Authentik + Tailscale secrets.

> **Shared-role note:** Tasks 5 (docker daemon.json, journald cap) touch `roles/docker` and `roles/base`, which all hosts use. These are written to be **behavior-preserving via defaults** so the 5 production hosts render identical or additive-only config; they take effect on those hosts only on their next deploy and are standard hardening. If you prefer these too be vps-only, they can move into the `hardening` role — flagged in Task 5.

---

## Phase A — Repo scaffolding (no live host required)

### Task 1: Inventory + host_vars for `vps-01`

**Files:**
- Modify: `inventory/hosts.yaml`
- Create: `host_vars/vps-01.yaml`

**Interfaces:**
- Produces: inventory host `vps-01` in group `cloud`; `services_configs` list (with `-vps` variants) consumed by the `services` role.

- [ ] **Step 1: Add `vps-01` to the `cloud` group.** Edit `inventory/hosts.yaml` under `cloud: hosts:` (keep `external-01`):

```yaml
    cloud:
      hosts:
        external-01:
          ansible_host: 192.168.92.60
          ansible_port: 4322
        vps-01:
          ansible_host: 100.64.0.0        # PLACEHOLDER: tailscale IP set after Task 14; public IP+22 used for first contact (Task 13)
          ansible_port: 4322
          ansible_user: dinos
```

- [ ] **Step 2: Create `host_vars/vps-01.yaml`:**

```yaml
is_local_vm: false

enable_proxy: true
enable_rss: true
enable_crowdsec: false
enable_cloudflare_tunnel: false
enable_hoarder: false

# Folder structure
app_folder_root: /opt/stacks

# Domain
hostname_root: "dinos.sh"
acme_provider: "cloudflare"
full_domain: "dinos.sh"
cloudflare_proxied: true

# Tailscale isolation
tailscale_hostname: vps-01
tailscale_tags: "tag:vps-edge"

# Break-glass SSH port (also used by hardening role)
ansible_port: 4322

services_configs:
  - name: docker-socket-proxy
  - name: traefik-vps
    required_folders:
      - logs
    touch_files:
      - acme.json
  - name: authentik
    required_folders:
      - media
      - custom-templates
      - certs
  - name: littlelink
  - name: freshrss
  - name: wallabag
    required_folders:
      - images
      - data
  - name: monitoring-client-vps
  - name: dozzle-vps
```

- [ ] **Step 3: Verify inventory parses.**

Run: `ansible-inventory -i inventory/hosts.yaml --host vps-01`
Expected: JSON prints with `full_domain: dinos.sh`, `is_local_vm: false`; `services_configs` lists the `-vps` names; no error.

- [ ] **Step 4: Commit.**

```bash
git add inventory/hosts.yaml host_vars/vps-01.yaml
git commit -m "feat(vps-01): add inventory host and host_vars with -vps service set"
```

---

### Task 2: Tailscale role

**Files:**
- Create: `roles/tailscale/tasks/main.yaml`, `roles/tailscale/defaults/main.yaml`
- Modify: `vars/vault.yaml` (add `vault_tailscale_authkey`)

**Interfaces:**
- Consumes: `tailscale_hostname`, `tailscale_tags` (host_vars), `vault_tailscale_authkey` (vault).
- Produces: host joined to tailnet as `tag:vps-edge`; `tailscale0` up; fact `tailscale_ip`.

- [ ] **Step 1: Add the auth key to vault.** `just decrypt`, add to `vars/vault.yaml`:

```yaml
vault_tailscale_authkey: "tskey-auth-REPLACE_ME"   # ephemeral, pre-authorized, scoped to tag:vps-edge
```
Then `just encrypt`.

- [ ] **Step 2: Create `roles/tailscale/defaults/main.yaml`:**

```yaml
tailscale_hostname: "{{ inventory_hostname }}"
tailscale_tags: "tag:vps-edge"
tailscale_authkey: "{{ vault_tailscale_authkey }}"
```

- [ ] **Step 3: Create `roles/tailscale/tasks/main.yaml`:**

```yaml
---
- name: Add Tailscale apt signing key
  ansible.builtin.get_url:
    url: "https://pkgs.tailscale.com/stable/debian/{{ ansible_distribution_release }}.noarmor.gpg"
    dest: /usr/share/keyrings/tailscale-archive-keyring.gpg
    mode: "0644"

- name: Add Tailscale apt repo
  ansible.builtin.get_url:
    url: "https://pkgs.tailscale.com/stable/debian/{{ ansible_distribution_release }}.tailscale-keyring.list"
    dest: /etc/apt/sources.list.d/tailscale.list
    mode: "0644"

- name: Install Tailscale
  ansible.builtin.apt:
    name: tailscale
    state: present
    update_cache: true

- name: Enable and start tailscaled
  ansible.builtin.systemd:
    name: tailscaled
    state: started
    enabled: true

- name: Bring up Tailscale with tag, no subnet acceptance
  ansible.builtin.command:
    cmd: >-
      tailscale up
      --authkey {{ tailscale_authkey }}
      --hostname {{ tailscale_hostname }}
      --advertise-tags {{ tailscale_tags }}
      --accept-routes=false
      --ssh=false
  register: ts_up
  changed_when: ts_up.rc == 0

- name: Get Tailscale IPv4
  ansible.builtin.command: tailscale ip -4
  register: ts_ip
  changed_when: false

- name: Store tailscale IP fact
  ansible.builtin.set_fact:
    tailscale_ip: "{{ ts_ip.stdout | trim }}"
```

> NOTE: On Ubuntu the same URL scheme works with the Ubuntu codename that `ansible_distribution_release` reports. Verify apt-based in Task 13.

- [ ] **Step 4: Commit** (syntax-check happens after Task 4 wires the role in).

```bash
git add roles/tailscale vars/vault.yaml
git commit -m "feat(tailscale): role to join tailnet as tag:vps-edge (no egress)"
```

---

### Task 3: Hardening role (firewall + sshd + fail2ban + logrotate + 0700 + pg_dump)

**Files:**
- Create: `roles/hardening/tasks/main.yaml`, `roles/hardening/handlers/main.yaml`
- Create: `roles/hardening/templates/{jail.local.j2,logrotate-traefik.j2,pg-backup.sh.j2,pg-backup.service.j2,pg-backup.timer.j2}`
- Modify: `group_vars/all.yaml` (add `mon_tailscale_ip`)

**Interfaces:**
- Consumes: `ansible_port` (break-glass SSH), `tailscale_ip` (Task 2), `mon_tailscale_ip`, `app_folder_root`.
- Produces: ufw ruleset (default-deny; CF-only 80/443; tailscale metrics + SSH); hardened sshd; fail2ban; traefik logrotate; `/opt/stacks/*` at `0700`; nightly pg_dump timer. **Runs only on vps-01** (in its play).

- [ ] **Step 1: Add `mon_tailscale_ip`** to `group_vars/all.yaml`:

```yaml
mon_tailscale_ip: "100.64.0.10"   # PLACEHOLDER: mon's tailscale IP; confirm in Task 18
```

- [ ] **Step 2: Create `roles/hardening/handlers/main.yaml`:**

```yaml
---
- name: Restart ssh service
  ansible.builtin.systemd:
    name: ssh
    state: restarted

- name: Reload ufw
  community.general.ufw:
    state: reloaded

- name: Restart fail2ban
  ansible.builtin.systemd:
    name: fail2ban
    state: restarted
```

- [ ] **Step 3: Create `roles/hardening/templates/jail.local.j2`:**

```ini
[sshd]
enabled = true
port = {{ ansible_port }}
maxretry = 4
findtime = 600
bantime = 3600
backend = systemd
```

- [ ] **Step 4: Create `roles/hardening/templates/logrotate-traefik.j2`:**

```jinja
{{ app_folder_root }}/traefik-vps/logs/*.log {
  size 20M
  daily
  rotate 14
  missingok
  notifempty
  compress
  delaycompress
  copytruncate
  postrotate
    docker kill --signal="USR1" traefik 2>/dev/null || true
  endscript
}
```

- [ ] **Step 5: Create the three pg-backup templates.**

`roles/hardening/templates/pg-backup.sh.j2`:
```bash
#!/usr/bin/env bash
set -euo pipefail
BACKUP_DIR="{{ app_folder_root }}/backups"
mkdir -p "$BACKUP_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
for c in authentik-postgresql {{ wallabag_db_container | default('wallabag-db') }} {{ freshrss_db_container | default('freshrss-db') }}; do
  if docker ps --format '{{ "{{.Names}}" }}' | grep -qx "$c"; then
    docker exec "$c" pg_dumpall -U postgres 2>/dev/null | gzip > "$BACKUP_DIR/${c}-${STAMP}.sql.gz" || true
  fi
done
find "$BACKUP_DIR" -name '*.sql.gz' -mtime +7 -delete
```

`roles/hardening/templates/pg-backup.service.j2`:
```ini
[Unit]
Description=Nightly Postgres logical backup

[Service]
Type=oneshot
ExecStart={{ app_folder_root }}/backups/pg-backup.sh
```

`roles/hardening/templates/pg-backup.timer.j2`:
```ini
[Unit]
Description=Run pg-backup nightly

[Timer]
OnCalendar=*-*-* 03:30:00
Persistent=true

[Install]
WantedBy=timers.target
```

- [ ] **Step 6: Create `roles/hardening/tasks/main.yaml`:**

```yaml
---
- name: Harden sshd (key-only, no root, custom port)
  ansible.builtin.lineinfile:
    dest: /etc/ssh/sshd_config
    regexp: "{{ item.regexp }}"
    line: "{{ item.line }}"
    validate: "sshd -t -f %s"
  loop:
    - { regexp: "^.*PasswordAuthentication", line: "PasswordAuthentication no" }
    - { regexp: "^.*PermitRootLogin", line: "PermitRootLogin no" }
    - { regexp: "^#?Port ", line: "Port {{ ansible_port }}" }
  notify: Restart ssh service

- name: Fetch Cloudflare IPv4 ranges
  ansible.builtin.uri: { url: https://www.cloudflare.com/ips-v4, return_content: true }
  register: cf_v4
  delegate_to: localhost
  become: false

- name: Fetch Cloudflare IPv6 ranges
  ansible.builtin.uri: { url: https://www.cloudflare.com/ips-v6, return_content: true }
  register: cf_v6
  delegate_to: localhost
  become: false

- name: Set Cloudflare CIDR facts
  ansible.builtin.set_fact:
    cloudflare_cidrs: "{{ (cf_v4.content.splitlines() + cf_v6.content.splitlines()) | select | list }}"

- name: UFW default deny incoming
  community.general.ufw: { direction: incoming, policy: deny }

- name: UFW default allow outgoing
  community.general.ufw: { direction: outgoing, policy: allow }

- name: UFW allow break-glass SSH (rate-limited)
  community.general.ufw:
    rule: limit
    direction: in
    to_port: "{{ ansible_port }}"
    proto: tcp
  notify: Reload ufw

- name: UFW allow 80/443 from Cloudflare ranges only
  community.general.ufw:
    rule: allow
    direction: in
    src: "{{ item.0 }}"
    to_port: "{{ item.1 }}"
    proto: tcp
  loop: "{{ cloudflare_cidrs | product(['80', '443']) | list }}"
  loop_control: { label: "{{ item.0 }}:{{ item.1 }}" }
  notify: Reload ufw

- name: UFW allow metrics scrape from mon over tailscale
  community.general.ufw:
    rule: allow
    direction: in
    interface: tailscale0
    src: "{{ mon_tailscale_ip }}"
    to_port: "{{ item }}"
    proto: tcp
  loop: ["9100", "8082"]
  notify: Reload ufw

- name: UFW allow admin SSH over tailscale
  community.general.ufw:
    rule: allow
    direction: in
    interface: tailscale0
    to_port: "{{ ansible_port }}"
    proto: tcp
  notify: Reload ufw

- name: Enable UFW
  community.general.ufw: { state: enabled, logging: "on" }

- name: Deploy fail2ban jail
  ansible.builtin.template:
    src: jail.local.j2
    dest: /etc/fail2ban/jail.local
    mode: "0644"
  notify: Restart fail2ban

- name: Enable fail2ban
  ansible.builtin.systemd: { name: fail2ban, state: started, enabled: true }

- name: Install Traefik logrotate config
  ansible.builtin.template:
    src: logrotate-traefik.j2
    dest: /etc/logrotate.d/traefik
    mode: "0644"

- name: Ensure backups dir exists
  ansible.builtin.file:
    path: "{{ app_folder_root }}/backups"
    state: directory
    mode: "0700"

- name: Install pg-backup script
  ansible.builtin.template:
    src: pg-backup.sh.j2
    dest: "{{ app_folder_root }}/backups/pg-backup.sh"
    mode: "0750"

- name: Install pg-backup systemd units
  ansible.builtin.template:
    src: "{{ item }}.j2"
    dest: "/etc/systemd/system/{{ item }}"
    mode: "0644"
  loop: [pg-backup.service, pg-backup.timer]

- name: Enable pg-backup timer
  ansible.builtin.systemd: { name: pg-backup.timer, state: started, enabled: true, daemon_reload: true }

- name: Tighten service directory permissions to 0700
  ansible.builtin.file:
    path: "{{ app_folder_root }}/{{ item.name }}"
    state: directory
    mode: "0700"
  loop: "{{ services_configs }}"
  loop_control: { label: "{{ item.name }}" }
```

> The 0700 task runs after `services` (see play order in Task 4), so directories already exist.

- [ ] **Step 7: Commit.**

```bash
git add roles/hardening group_vars/all.yaml
git commit -m "feat(hardening): vps-only firewall, sshd, fail2ban, logrotate, 0700 dirs, pg_dump timer"
```

---

### Task 4: Add the `vps-01` play to `site.yaml`

**Files:**
- Modify: `site.yaml`

**Interfaces:**
- Produces: dedicated play running `grog.package, base, docker, tailscale, services, hardening` (services BEFORE hardening so 0700 applies to existing dirs). Legacy cloud play scoped to `external-01`.

- [ ] **Step 1: Add a new play** before the existing `Setup cloud servers` play:

```yaml
- name: Setup OVH public VPS
  hosts: vps-01
  become: true
  vars_files:
    - vars/vault.yaml
  roles:
    - role: grog.package
    - role: base
    - role: docker
    - role: tailscale
    - role: services
      tags: configs
    - role: hardening
```

- [ ] **Step 2: Scope the legacy cloud play** — change its `hosts: cloud` to `hosts: external-01`.

- [ ] **Step 3: Syntax-check.**

Run: `ansible-playbook -i inventory/hosts.yaml site.yaml --syntax-check`
Expected: no errors.

- [ ] **Step 4: Verify only vps-01 matches the new play.**

Run: `ansible-playbook -i inventory/hosts.yaml site.yaml --list-hosts --limit vps-01`
Expected: the "Setup OVH public VPS" play lists `vps-01`.

- [ ] **Step 5: Commit.**

```bash
git add site.yaml
git commit -m "feat(vps-01): dedicated site.yaml play (services before hardening)"
```

---

### Task 5: Docker daemon log rotation + journald cap

**IMPORTANT — reconciled with existing code:** `roles/docker` ALREADY deploys `daemon.json`
from a **static** `roles/docker/files/daemon.json` (currently `max-size: 100m`, `max-file: 3`)
via an existing task named **"Copy daemon.json"** that notifies the handler **`Restart Docker`**
(capital D). The docker role also **already creates the `proxy` network**. Do NOT add a second
daemon.json task. Instead, convert the existing static file to a template driven by a variable
whose **default preserves 100m** for the 5 other hosts, overridden to `10m` only on `vps-01`.
Role files use the `.yml` extension.

**Files:**
- Create: `roles/docker/templates/daemon.json.j2`
- Delete: `roles/docker/files/daemon.json`
- Modify: `roles/docker/tasks/main.yml` (change the existing "Copy daemon.json" task from `copy`→`template`)
- Modify: `roles/base/tasks/main.yaml` (+ `Restart journald` handler in `roles/base/handlers/main.yaml`)
- Modify: `group_vars/all.yaml` (defaults; 100m preserves current behavior)
- Modify: `host_vars/vps-01.yaml` (override to 10m)

**Interfaces:**
- Produces: templated docker log caps (default 100m, vps-01 = 10m, adds `live-restore`); bounded journald.

- [ ] **Step 1: Add defaults** to `group_vars/all.yaml` (default 100m keeps the 5 production hosts identical):

```yaml
docker_log_max_size: "100m"
docker_log_max_file: "3"
journald_system_max_use: "500M"
```

- [ ] **Step 2: Override for vps-01** — add to `host_vars/vps-01.yaml`:

```yaml
docker_log_max_size: "10m"
```

- [ ] **Step 3: Create `roles/docker/templates/daemon.json.j2`:**

```jinja
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "{{ docker_log_max_size }}",
    "max-file": "{{ docker_log_max_file }}"
  },
  "live-restore": true
}
```

- [ ] **Step 4: Delete the static file and switch the existing task to a template.**

`git rm roles/docker/files/daemon.json`. In `roles/docker/tasks/main.yml`, change the existing
**"Copy daemon.json"** task from `ansible.builtin.copy: { src: daemon.json, ... }` to:

```yaml
- name: Copy daemon.json
  ansible.builtin.template:
    src: daemon.json.j2
    dest: /etc/docker/daemon.json
    owner: root
    group: root
    mode: '0644'
  notify: Restart Docker
```

(Keep the handler name `Restart Docker` exactly — it already exists in `roles/docker/handlers/main.yml`. Do NOT add a new handler.)

- [ ] **Step 5: Cap journald** — add to `roles/base/tasks/main.yaml` (ungated, so it applies to vps-01; benign on other hosts):

```yaml
- name: Cap journald disk usage
  ansible.builtin.lineinfile:
    path: /etc/systemd/journald.conf
    regexp: "^#?SystemMaxUse="
    line: "SystemMaxUse={{ journald_system_max_use }}"
  notify: Restart journald
```

Add to `roles/base/handlers/main.yaml`:

```yaml
- name: Restart journald
  become: true
  ansible.builtin.systemd:
    name: systemd-journald
    state: restarted
```

- [ ] **Step 6: Verify template renders 100m by default and 10m for vps-01, then commit.**

Run: `ansible-playbook -i inventory/hosts.yaml site.yaml --syntax-check`
Sanity: `git grep -n "src: daemon.json" roles/docker` should return NOTHING (task now uses the template).

```bash
git add roles/docker roles/base group_vars/all.yaml host_vars/vps-01.yaml
git commit -m "feat(docker/base): template daemon.json log caps (100m default, 10m vps-01) + journald cap"
```

---

### Task 6: docker-socket-proxy config (vps-only)

**Files:**
- Create: `configs/docker-socket-proxy/docker-compose.yaml`, `configs/docker-socket-proxy/.env.st`

**Interfaces:**
- Produces: `docker-socket-proxy` on the `proxy` network exposing a read-only Docker API at `tcp://docker-socket-proxy:2375`. Consumed by `traefik-vps` and `dozzle-vps`.

- [ ] **Step 1: Create `configs/docker-socket-proxy/docker-compose.yaml`:**

```yaml
services:
  docker-socket-proxy:
    image: ghcr.io/tecnativa/docker-socket-proxy:0.3.0
    container_name: docker-socket-proxy
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    environment:
      CONTAINERS: 1
      IMAGES: 1
      NETWORKS: 1
      SERVICES: 0
      TASKS: 0
      POST: 0
      EVENTS: 1
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      - proxy
    read_only: true
    tmpfs:
      - /run

networks:
  proxy:
    external: true
```

- [ ] **Step 2: Create `configs/docker-socket-proxy/.env.st`:**

```jinja
TZ={{ default_timezone }}
```

- [ ] **Step 3: Commit.**

```bash
git add configs/docker-socket-proxy
git commit -m "feat(vps-01): read-only docker-socket-proxy config"
```

---

### Task 7: `traefik-vps` hardened config (dedicated copy)

**Files:**
- Create: `configs/traefik-vps/docker-compose.yaml`, `configs/traefik-vps/traefik.yml.j2`, `configs/traefik-vps/config.yml.j2`, `configs/traefik-vps/.env.st`

**Interfaces:**
- Consumes: `docker-socket-proxy` (Task 6), Authentik embedded outpost at `authentik-server:9000`.
- Produces: Traefik with Docker provider over the socket-proxy, no crowdsec, `authentik@file` middleware, Authentik-protected dashboard.

- [ ] **Step 1: Copy the shared traefik config as the starting point:**

```bash
mkdir -p configs/traefik-vps
cp configs/traefik/traefik.yml.j2 configs/traefik-vps/traefik.yml.j2
cp configs/traefik/config.yml.j2 configs/traefik-vps/config.yml.j2
cp configs/traefik/.env.st configs/traefik-vps/.env.st
cp configs/traefik/docker-compose.yaml configs/traefik-vps/docker-compose.yaml
```

- [ ] **Step 2: In `configs/traefik-vps/traefik.yml.j2`** — (a) change the Docker provider endpoint; (b) delete the crowdsec `experimental: plugins: bouncer` block at the bottom (the whole `{% if cloudflare_proxied %}experimental...{% endif %}`). Keep the `forwardedHeaders`/`proxyProtocol` CF trusted-IP blocks (still proxied):

```yaml
providers:
  docker:
    endpoint: "tcp://docker-socket-proxy:2375"
    exposedByDefault: false
  file:
    filename: /config.yml
    watch: true
```

- [ ] **Step 3: In `configs/traefik-vps/config.yml.j2`** — remove the crowdsec middleware block; add the Authentik forward-auth middleware, service, and outpost router. Full file:

```jinja
http:
  middlewares:
    authentik:
      forwardAuth:
        address: "http://authentik-server:9000/outpost.goauthentik.io/auth/traefik"
        trustForwardHeader: true
        authResponseHeaders:
          - X-authentik-username
          - X-authentik-groups
          - X-authentik-email
          - X-authentik-name
          - X-authentik-uid
  services:
    authentik:
      loadBalancer:
        servers:
          - url: "http://authentik-server:9000/"
  routers:
    metrics:
      entryPoints:
        - https
      rule: "Host(`traefik.{{ full_domain }}`) && PathPrefix(`/metrics`)"
      service: prometheus@internal
      tls: {}
    authentik-outpost:
      entryPoints:
        - https
      rule: "HostRegexp(`{subdomain:[a-z0-9-]+}.{{ full_domain }}`) && PathPrefix(`/outpost.goauthentik.io/`)"
      service: authentik@file
      tls: {}
```

- [ ] **Step 4: In `configs/traefik-vps/docker-compose.yaml`** — (a) delete the `- /var/run/docker.sock:/var/run/docker.sock:ro` volume line; (b) replace the dashboard basic-auth with Authentik: remove the `traefik-auth.basicauth.users` label and set the secure router middleware:

```yaml
      - "traefik.http.routers.traefik-secure.middlewares=authentik@file"
```

- [ ] **Step 5: Verify no crowdsec/socket references remain.**

Run: `grep -nE "crowdsec|bouncer|docker.sock" configs/traefik-vps/* || echo "CLEAN"`
Expected: `CLEAN`.

- [ ] **Step 6: Commit.**

```bash
git add configs/traefik-vps
git commit -m "feat(vps-01): traefik-vps hardened config (socket-proxy, no crowdsec, authentik)"
```

---

### Task 8: `dozzle-vps` config (dedicated)

**Files:**
- Create: `configs/dozzle-vps/docker-compose.yaml`, `configs/dozzle-vps/.env.st`

**Interfaces:**
- Consumes: `docker-socket-proxy` (Task 6), `authentik@file` middleware (Task 7).
- Produces: Dozzle reading logs via the socket-proxy, protected by Authentik.

- [ ] **Step 1: Create `configs/dozzle-vps/docker-compose.yaml`:**

```yaml
services:
  dozzle:
    image: amir20/dozzle:v10.6.5
    container_name: dozzle
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    env_file:
      - .env
    environment:
      - TZ=${TZ}
      - DOZZLE_AUTH_PROVIDER=none
      - DOZZLE_LEVEL=info
      - DOZZLE_REMOTE_HOST=tcp://docker-socket-proxy:2375
    networks:
      - proxy
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.dozzle.rule=Host(`dozzle.${FULL_DOMAIN}`)"
      - "traefik.http.routers.dozzle.entrypoints=https"
      - "traefik.http.routers.dozzle.tls=true"
      - "traefik.http.routers.dozzle.middlewares=authentik@file"
      - "traefik.http.services.dozzle.loadbalancer.server.port=8080"

networks:
  proxy:
    external: true
```

- [ ] **Step 2: Create `configs/dozzle-vps/.env.st`** (mirror the shared dozzle `.env.st` — inspect `configs/dozzle/.env.st` and copy its variables; at minimum):

```jinja
TZ={{ default_timezone }}
FULL_DOMAIN={{ full_domain }}
```

- [ ] **Step 3: Commit.**

```bash
git add configs/dozzle-vps
git commit -m "feat(vps-01): dozzle-vps via socket-proxy + authentik"
```

---

### Task 9: Authentik middleware on FreshRSS + Wallabag

**Files:**
- Modify: `configs/freshrss/docker-compose.yaml`
- Modify: `configs/wallabag/docker-compose.yaml`

**Interfaces:**
- Consumes: `authentik@file` middleware (Task 7).
- Produces: freshrss/wallabag routers protected by Authentik. (external-01-only services; external-01 is being retired and won't be redeployed.)

- [ ] **Step 1: Inspect both compose files** to find the exact HTTPS router name and any existing `middlewares=` label.

- [ ] **Step 2: Add/extend the middleware label on the HTTPS router** in each file. If a `middlewares=` label already exists, comma-append `authentik@file`; else add:

```yaml
      - "traefik.http.routers.freshrss.middlewares=authentik@file"
```
```yaml
      - "traefik.http.routers.wallabag.middlewares=authentik@file"
```
(Use the actual router names discovered in Step 1.)

- [ ] **Step 3: Commit.**

```bash
git add configs/freshrss/docker-compose.yaml configs/wallabag/docker-compose.yaml
git commit -m "feat(sso): protect freshrss and wallabag with authentik forward-auth"
```

---

### Task 10: `monitoring-client-vps` (exporters only, no promtail)

**Files:**
- Create: `configs/monitoring-client-vps/docker-compose.yaml`, `configs/monitoring-client-vps/.env.st`

**Interfaces:**
- Produces: `node-exporter` (9100) + `cadvisor` (host 8082) only — no promtail, so no log egress. Scraped by `mon` over tailscale.

- [ ] **Step 1: Inspect `configs/monitoring-client/`** for the full file set (compose + `.env.st` + any `promtail/` folder) so the `-vps` copy carries the exporter parts verbatim.

- [ ] **Step 2: Create `configs/monitoring-client-vps/docker-compose.yaml`** — copy the shared file but **remove the `promtail` service entirely** (keep `node-exporter` and `cadvisor` exactly as in the shared file, including ports `9100:9100` and `8082:8080`, volumes, labels).

- [ ] **Step 3: Create `configs/monitoring-client-vps/.env.st`** — copy from `configs/monitoring-client/.env.st`, dropping any promtail/`TRAEFIK_LOGS_DIR`-only variables that are no longer referenced.

- [ ] **Step 4: Verify no promtail remains.**

Run: `grep -n "promtail" configs/monitoring-client-vps/* || echo "NO PROMTAIL"`
Expected: `NO PROMTAIL`.

- [ ] **Step 5: Commit.**

```bash
git add configs/monitoring-client-vps
git commit -m "feat(vps-01): monitoring-client-vps exporters only (no log egress)"
```

---

### Task 11: Authentik secrets in vault + `.env.st`

**Files:**
- Modify: `vars/vault.yaml`
- Verify/Modify: `configs/authentik/.env.st`

**Interfaces:**
- Produces: `PG_PASS`, `AUTHENTIK_SECRET_KEY`, `PG_USER`, `PG_DB`, `FULL_DOMAIN`, `TZ` available to the authentik compose.

- [ ] **Step 1: Inspect `configs/authentik/.env.st`** and confirm the variable names it references.

- [ ] **Step 2: Add secrets to vault.** `just decrypt`, add:

```yaml
vault_authentik_pg_pass: "REPLACE_STRONG_PW"
vault_authentik_secret_key: "REPLACE_50_CHAR_RANDOM"   # openssl rand -base64 60
```
`just encrypt`.

- [ ] **Step 3: Ensure `.env.st` binds them:**

```jinja
PG_PASS={{ vault_authentik_pg_pass }}
PG_USER=authentik
PG_DB=authentik
AUTHENTIK_SECRET_KEY={{ vault_authentik_secret_key }}
FULL_DOMAIN={{ full_domain }}
TZ={{ default_timezone }}
```

- [ ] **Step 4: Verify vault stays encrypted.**

Run: `head -1 vars/vault.yaml`
Expected: `$ANSIBLE_VAULT;1.1;AES256`.

- [ ] **Step 5: Commit.**

```bash
git add vars/vault.yaml configs/authentik/.env.st
git commit -m "feat(authentik): vault secrets and env bindings"
```

---

## Phase B — Provision & bootstrap (requires the live VPS)

### Task 12: First contact + admin user

**Files:** none (operational).

- [ ] **Step 1: Confirm OS is apt-based.**

Run: `ssh <ovh-default-user>@<vps-public-ip> 'cat /etc/os-release'`
Expected: `ID=debian` or `ID=ubuntu`. If not apt-based, STOP and revisit roles.

- [ ] **Step 2: Create admin user + key + sudo:**

```bash
ssh <ovh-default-user>@<vps-public-ip> 'sudo useradd -m -s /bin/bash -G sudo dinos && sudo mkdir -p /home/dinos/.ssh && sudo chmod 700 /home/dinos/.ssh'
ssh-copy-id -i ~/.ssh/id_ed25519.pub dinos@<vps-public-ip>
ssh <ovh-default-user>@<vps-public-ip> 'echo "dinos ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/dinos && sudo chmod 440 /etc/sudoers.d/dinos'
```

- [ ] **Step 3: Verify.**

Run: `ssh dinos@<vps-public-ip> 'sudo whoami'`
Expected: `root`.

- [ ] **Step 4: Temporarily point inventory at the public IP on port 22** for the first run: set `vps-01.ansible_host: <public-ip>`, `ansible_port: 22`. (No commit; reverted in Task 14.)

---

### Task 13: Base + Docker + Tailscale bring-up

**Files:** none (operational).

- [ ] **Step 1: Ensure the `proxy` docker network exists.**

Run: `ssh dinos@<vps-public-ip> 'docker network create proxy 2>/dev/null || echo exists'`
(If a role already creates it, this is a no-op. Verify during Step 2.)

- [ ] **Step 2: Run base + docker + tailscale, skipping services + hardening** (bring the tunnel up before SSH lockdown):

Run: `ansible-playbook -i inventory/hosts.yaml site.yaml --limit vps-01 --skip-tags configs`
Then verify `tailscale up` succeeded and note the printed `tailscale_ip`.

> If you need to stop before `hardening` runs (which changes the SSH port), run only up to tailscale using `--start-at-task` or temporarily comment the `hardening` role for this bring-up run; re-enable for Task 14.

- [ ] **Step 3: Verify tailnet join + tag.**

Run: `tailscale status | grep vps-01`
Expected: `vps-01` present with `tag:vps-edge`.

- [ ] **Step 4: Apply the tailnet ACL** in the Tailscale admin console:

```jsonc
"tagOwners": { "tag:vps-edge": ["autogroup:admin"] },
"acls": [
  { "action": "accept", "src": ["tag:mon"], "dst": ["tag:vps-edge:9100,8082"] },
  { "action": "accept", "src": ["<your-admin-device>"], "dst": ["tag:vps-edge:4322"] }
]
```

- [ ] **Step 5: Prove egress is blocked.**

Run: `ssh dinos@<vps-tailscale-ip> 'tailscale ping mon || echo BLOCKED-AS-EXPECTED'`
Expected: fails / `BLOCKED-AS-EXPECTED`.

---

### Task 14: Lock down SSH + switch inventory to Tailscale

**Files:**
- Modify: `inventory/hosts.yaml`

- [ ] **Step 1: Run the full play** (now includes hardening → sets custom SSH port + firewall):

Run: `ansible-playbook -i inventory/hosts.yaml site.yaml --limit vps-01 --skip-tags configs`
(Services still skipped; hardening applies. sshd Port becomes 4322.)

- [ ] **Step 2: Point inventory at tailscale IP + custom port:**

```yaml
        vps-01:
          ansible_host: <vps-tailscale-ip>
          ansible_port: 4322
          ansible_user: dinos
```

- [ ] **Step 3: Verify Ansible reaches it over tailscale.**

Run: `ansible -i inventory/hosts.yaml vps-01 -m ping`
Expected: `pong`.

- [ ] **Step 4: Verify firewall.**

Run:
```bash
nc -vz -w5 <vps-public-ip> 4322
nc -vz -w5 <vps-public-ip> 443 && echo "OPEN (should be refused from non-CF)"
```
Expected: 4322 open; 443 refused/timeout from your non-Cloudflare IP.

- [ ] **Step 5: Commit inventory.**

```bash
git add inventory/hosts.yaml
git commit -m "chore(vps-01): point inventory at tailscale IP + custom ssh port"
```

---

### Task 15: Deploy the full service stack

**Files:** none (operational).

- [ ] **Step 1: Deploy.**

Run: `just run-machine vps-01`
Expected containers up: docker-socket-proxy, traefik (from traefik-vps), authentik-{postgresql,redis,server,worker}, littlelink, freshrss, wallabag, node-exporter, cadvisor, dozzle. No promtail, no crowdsec, no cloudflared.

- [ ] **Step 2: Verify container health.**

Run: `ssh vps-01 'docker ps --format "{{ "{{.Names}}\t{{.Status}}" }}"'`
Expected: all `Up`/`healthy`; `promtail`/`crowdsec` absent.

- [ ] **Step 3: Verify Traefik has no direct socket mount.**

Run: `ssh vps-01 'docker inspect traefik --format "{{ "{{ .HostConfig.Binds }}" }}"'`
Expected: no `/var/run/docker.sock`.

- [ ] **Step 4: Verify TLS issued** (pre-cutover use `--resolve`):

Run: `curl -sI --resolve littlelink.dinos.sh:443:<vps-public-ip> https://littlelink.dinos.sh`
Expected: `HTTP/2 200`, valid Let's Encrypt cert.

---

### Task 16: Configure Authentik

**Files:** none (Authentik UI).

- [ ] **Step 1: Bootstrap admin** at `https://auth.dinos.sh/if/flow/initial-setup/` (use `--resolve` pre-cutover). Set akadmin password.
- [ ] **Step 2: Create Proxy Provider(s)** (forward-auth) — one domain-level provider for `*.dinos.sh` or one per app.
- [ ] **Step 3: Bind the embedded outpost** to the provider(s).
- [ ] **Step 4: Create Applications** for freshrss, wallabag, dozzle, traefik-dashboard with an access policy (your user/group).
- [ ] **Step 5: Verify** — visiting `https://dozzle.dinos.sh` redirects to Authentik login, then loads after auth.

---

### Task 17: End-to-end verification

**Files:** none.

- [ ] **Step 1:** On `mon`, confirm Prometheus targets `vps-01` node-exporter/cadvisor over tailscale are `UP`.
- [ ] **Step 2:** `ssh vps-01 'curl -m5 http://<mon-tailscale-ip>:3100/ready || echo BLOCKED'` → `BLOCKED` (no Loki egress).
- [ ] **Step 3:** From a non-CF IP: `curl -m5 https://<vps-public-ip>` → refused; via CF hostname → 200.
- [ ] **Step 4:** `ssh vps-01 'docker logs --tail 5 traefik'` and Dozzle UI show logs; nothing for vps-01 in central Loki.
- [ ] **Step 5:** `ssh vps-01 'sudo systemctl start pg-backup.service && ls /opt/stacks/backups'` → dumps exist.
- [ ] **Step 6:** `ssh vps-01 'cat /etc/docker/daemon.json'` shows `max-size 10m`; `sudo logrotate -d /etc/logrotate.d/traefik` dry-run is clean.
- [ ] **Step 7:** `ssh vps-01 'stat -c "%a %n" /opt/stacks/*'` → service dirs `700`.

---

## Phase C — Data migration & cutover (hard cutover)

### Task 18: Migrate Wallabag data

**Files:** none (operational).

- [ ] **Step 1: Enable OVH provider backups/snapshots** for `vps-01` in the OVH panel; confirm one snapshot completes.
- [ ] **Step 2: Verify Wallabag DB engine** in `configs/wallabag/docker-compose.yaml` before dumping (Postgres vs MariaDB/SQLite) and adjust the dump command accordingly.
- [ ] **Step 3: Quiesce old Wallabag** on `external-01`: `docker compose -f /opt/stacks/wallabag/docker-compose.yaml stop`.
- [ ] **Step 4: Dump + archive** on `external-01`:

```bash
docker exec <wallabag-db> pg_dumpall -U postgres | gzip > /tmp/wallabag.sql.gz
tar czf /tmp/wallabag-data.tgz -C /opt/stacks/wallabag images data
```

- [ ] **Step 5: Relay via admin machine** (VPS can't initiate to old VM):

```bash
scp external-01:/tmp/wallabag.sql.gz external-01:/tmp/wallabag-data.tgz /tmp/
scp /tmp/wallabag.sql.gz /tmp/wallabag-data.tgz vps-01:/tmp/
```

- [ ] **Step 6: Restore on vps-01** and restart:

```bash
ssh vps-01 'cd /opt/stacks/wallabag && tar xzf /tmp/wallabag-data.tgz -C /opt/stacks/wallabag && gunzip -c /tmp/wallabag.sql.gz | docker exec -i <wallabag-db> psql -U postgres'
ssh vps-01 'docker compose -f /opt/stacks/wallabag/docker-compose.yaml up -d'
```

- [ ] **Step 7: Verify** entry count at `https://wallabag.dinos.sh` (via `--resolve`).

---

### Task 19: Migrate FreshRSS data

**Files:** none (operational).

- [ ] **Step 1: Verify FreshRSS storage engine** in `configs/freshrss/docker-compose.yaml` (Postgres → DB dump; SQLite → copy the `data/` volume).
- [ ] **Step 2: Export** on `external-01` (DB dump preferred; OPML export from UI as fallback).
- [ ] **Step 3: Relay via admin machine** (same pattern as Task 18 Step 5).
- [ ] **Step 4: Restore** on vps-01 (DB import or OPML import after creating the user).
- [ ] **Step 5: Verify** feeds at `https://freshrss.dinos.sh`.

---

### Task 20: DNS cutover + decommission

**Files:**
- Modify: `inventory/hosts.yaml`, `site.yaml`; delete `host_vars/external-01.yaml`

- [ ] **Step 1: Pre-lower TTL** (~24h earlier) on affected Cloudflare records.
- [ ] **Step 2: Flip DNS** — replace tunnel CNAMEs with proxied A/AAAA → vps-01 public IP for: `links`/root, `freshrss`, `wallabag`, `dozzle`, `auth`, `traefik-dashboard` (exporters can stay internal). Orange cloud ON.
- [ ] **Step 3: Smoke test:**

```bash
for h in links freshrss wallabag dozzle auth traefik-dashboard; do
  echo "== $h =="; curl -sI https://$h.dinos.sh | head -1
done
```
Expected: `200`/`302` (auth redirect); valid certs; served by vps-01.

- [ ] **Step 4: Decommission** — power off `external-01`; after confidence, remove it from `inventory/hosts.yaml`, delete the legacy `Setup cloud servers` / `hosts: external-01` play from `site.yaml`, and `git rm host_vars/external-01.yaml`.
- [ ] **Step 5: Commit.**

```bash
git add inventory/hosts.yaml site.yaml
git rm host_vars/external-01.yaml
git commit -m "chore: decommission external-01 after vps-01 cutover"
```

- [ ] **Step 6:** Confirm the OVH snapshot + `pg_dump` timer have run at least once post-cutover.

---

## Self-Review Notes

- **Spec coverage:** §1 identity → Task 1; §2 exposure/CF firewall → Task 3; §3 SSH/bootstrap → Tasks 12–14; §4 tailscale ACL + promtail drop → Tasks 2,10,13; §5 socket-proxy/hardening → Tasks 6,7,8; §6 hardened .env (0600 already in services role) + 0700 dirs → Task 3; §7 authentik SSO → Tasks 7,9,11,16; §8 data migration + backups → Tasks 3,18,19; §9 log rotation → Tasks 3,5; §10 cutover → Task 20; §11 integration/testing → Tasks 4,17.
- **Option 2 isolation:** shared `configs/traefik`, `configs/dozzle`, `configs/monitoring-client` and the `services` role are NOT modified; vps-01 uses `traefik-vps`/`dozzle-vps`/`monitoring-client-vps`. freshrss/wallabag/littlelink are external-01-only (Task 9 edits are safe).
- **Shared-role exception:** Task 5 touches `roles/docker`+`roles/base` with behavior-preserving defaults; noted for the reviewer, with the option to relocate into `hardening` if strict vps-only is required.
- **Placeholders to fill during execution:** tailscale IPs (vps + mon), vps public IP, admin device identity, DB container names — all flagged inline.
- **Assumptions to verify:** Wallabag/FreshRSS DB engines (Tasks 18–19 Step 1/2 check before dumping); `proxy` network creation (Task 13 Step 1 guards it); OS apt-based (Task 12 Step 1).
```