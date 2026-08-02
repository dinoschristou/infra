# OVH `vps-01` Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the local Proxmox VM `external-01` (public `dinos.sh` services behind a Cloudflare Tunnel) with a hardened, container-based OVH VPS `vps-01` that is directly exposed behind Cloudflare's proxy, joined to Tailscale but isolated from other tailnet nodes, and fronts all non-public apps with Authentik SSO.

**Architecture:** Ansible-managed Debian/Ubuntu host in the `cloud` inventory group. Traefik terminates TLS on 80/443, reachable only from Cloudflare IP ranges (host firewall) with Cloudflare DNS-01 ACME. Docker workloads are hardened (socket-proxy, least-privilege). Authentik (local Postgres+Redis+server+worker) provides OIDC/forward-auth. Management is via Tailscale (primary) plus a locked-down public break-glass SSH port.

**Tech Stack:** Ansible, Docker Compose (`community.docker.docker_compose_v2`), Traefik v3, Authentik, Tailscale, nftables/ufw, Cloudflare (proxied DNS + DNS-01), restic-free OVH provider backups + local `pg_dump`.

## Global Constraints

- Target host: `vps-01`, OVH, 12 GB RAM / 6 vCPU / 100 GB disk. Public IPv4 (+IPv6 if provided).
- `app_folder_root: /opt/stacks`; domain `dinos.sh`; `acme_provider: cloudflare`; `cloudflare_proxied: true`; `is_local_vm: false`.
- Exposure: inbound **80/443 only from Cloudflare IP ranges**; break-glass SSH on a custom port; everything else default-deny. Tailscale interface allows only `mon → 9100,8082` and `admin-device → SSH`.
- Tailscale tag: `tag:vps-edge`, **no egress** to other tailnet nodes (local logs only; metrics are pull).
- Secrets: ansible-vault source of truth; rendered `.env` files `0600`, service dirs `0700`.
- Drop services: `cloudflared`, `crowdsec`, `karakeep`, `linkwarden`, and `promtail` (from monitoring-client). Add: `authentik`, `docker-socket-proxy`.
- SSO: freshrss/wallabag/dozzle/traefik-dashboard via Authentik forward-auth; littlelink public.
- All secrets committed to git MUST be inside the ansible-vault-encrypted `vars/vault.yaml`.
- Every deploy runs from the repo with `ansible-playbook -i inventory/hosts.yaml site.yaml --limit vps-01`.

---

## File Structure

**New files**
- `roles/tailscale/tasks/main.yaml` — install Tailscale, bring up with tag, disable other-node egress via `--accept-routes=false`.
- `roles/tailscale/defaults/main.yaml` — auth key var name, tags, hostname.
- `roles/hardening/tasks/main.yaml` — public-host firewall (CF ranges for 80/443, tailscale-only metrics, break-glass SSH), fail2ban, sshd hardening for `is_local_vm: false`.
- `roles/hardening/templates/jail.local.j2` — fail2ban jail for sshd on custom port.
- `configs/docker-socket-proxy/docker-compose.yaml` — read-only socket proxy.
- `configs/docker-socket-proxy/.env.st` — TZ.
- `host_vars/vps-01.yaml` — service list + host vars.
- `docs/superpowers/plans/…` (this file).

**Modified files**
- `inventory/hosts.yaml` — add `vps-01` to `cloud`; remove `external-01` at cutover.
- `group_vars/all.yaml` — add `enable_crowdsec: true` default (decouple from `cloudflare_proxied`); add `docker_log_max_size`/`docker_log_max_file` defaults.
- `group_vars/cloud.yaml` — (unchanged `is_local_vm: false`) add cloud-group defaults if needed.
- `site.yaml` — add a dedicated `vps-01` play (base + docker + tailscale + hardening + services); keep legacy `cloud` play for `external-01` until decommission.
- `configs/traefik/traefik.yml.j2` — gate crowdsec plugin on `enable_crowdsec`, not `cloudflare_proxied`; add `/etc/docker/daemon.json` log note; route Docker provider through socket-proxy.
- `configs/traefik/config.yml.j2` — gate crowdsec middleware on `enable_crowdsec`; add reusable `authentik` forward-auth middleware.
- `configs/traefik/docker-compose.yaml` — remove direct `docker.sock` mount, point provider at socket-proxy; add hardening opts + logrotate-friendly labels.
- `configs/dozzle/docker-compose.yaml` — use socket-proxy; swap `traefik-auth@docker` → `authentik@file` middleware.
- `configs/freshrss/docker-compose.yaml`, `configs/wallabag/docker-compose.yaml` — add `authentik@file` middleware label.
- `configs/monitoring-client/docker-compose.yaml` — make `promtail` conditional (removed for `vps-01`).
- `roles/base/tasks/main.yaml` — add `/etc/docker/daemon.json` log-rotation (or place in `docker` role); journald cap.
- `roles/hardening` wired for `is_local_vm: false` hosts.
- `vars/vault.yaml` — add Authentik + Tailscale secrets.

---

## Phase A — Repo scaffolding (no live host required)

### Task 1: Inventory + host_vars for `vps-01`

**Files:**
- Modify: `inventory/hosts.yaml`
- Create: `host_vars/vps-01.yaml`

**Interfaces:**
- Produces: inventory host `vps-01` in group `cloud`; `services_configs` list consumed by the `services` role.

- [ ] **Step 1: Add `vps-01` to the `cloud` group.** Edit `inventory/hosts.yaml`, under `cloud: hosts:` add (keep `external-01` for now):

```yaml
    cloud:
      hosts:
        external-01:
          ansible_host: 192.168.92.60
          ansible_port: 4322
        vps-01:
          ansible_host: 100.64.0.0        # PLACEHOLDER: replace with tailscale IP after Task 15
          ansible_port: 4322              # break-glass/custom SSH port set in Task 16
          ansible_user: dinos             # admin user created in Task 15
```

- [ ] **Step 2: Create `host_vars/vps-01.yaml`.** Mirror `external-01.yaml` with the agreed service set:

```yaml
is_local_vm: false

enable_proxy: true
enable_rss: true          # freshrss
enable_crowdsec: false    # dropped
enable_cloudflare_tunnel: false  # dropped
enable_hoarder: false     # karakeep dropped

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

# monitoring-client: exporters only, no promtail (no log egress)
monitoring_client_promtail: false

services_configs:
  - name: docker-socket-proxy
  - name: traefik
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
  - name: monitoring-client
  - name: dozzle
```

- [ ] **Step 3: Verify inventory parses.**

Run: `ansible-inventory -i inventory/hosts.yaml --host vps-01`
Expected: JSON prints with `full_domain: dinos.sh`, `is_local_vm: false`, no error.

- [ ] **Step 4: Commit.**

```bash
git add inventory/hosts.yaml host_vars/vps-01.yaml
git commit -m "feat(vps-01): add inventory host and host_vars"
```

---

### Task 2: Decouple crowdsec from `cloudflare_proxied` in Traefik

**Files:**
- Modify: `group_vars/all.yaml`
- Modify: `configs/traefik/traefik.yml.j2`
- Modify: `configs/traefik/config.yml.j2`

**Interfaces:**
- Produces: `enable_crowdsec` variable (default `true`) that gates crowdsec so `cloudflare_proxied: true` no longer implies crowdsec. `vps-01` sets `enable_crowdsec: false` (Task 1).

- [ ] **Step 1: Add the default.** In `group_vars/all.yaml`, after `cloudflare_proxied: false`, add:

```yaml
# Gate crowdsec bouncer independently of cloudflare_proxied.
# Legacy hosts keep it on; vps-01 sets this false in host_vars.
enable_crowdsec: true
```

- [ ] **Step 2: Re-gate the crowdsec plugin block** at the bottom of `configs/traefik/traefik.yml.j2`. Change the guard from `cloudflare_proxied` to `enable_crowdsec`:

```jinja
{% if enable_crowdsec %}
# crowdsec bouncer
experimental:
  plugins:
    bouncer:
      moduleName: github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin
      version: v1.4.2
{% endif %}
```

Leave the two `{% if cloudflare_proxied %}` `forwardedHeaders`/`proxyProtocol` trusted-IP blocks unchanged — `vps-01` still wants those (it IS proxied).

- [ ] **Step 3: Re-gate the crowdsec middleware** in `configs/traefik/config.yml.j2`. Change `{% if cloudflare_proxied %}` wrapping the `middlewares: crowdsec:` block to `{% if enable_crowdsec %}` (only that block; keep the `routers: metrics:` block outside any crowdsec guard).

- [ ] **Step 4: Verify template renders for vps-01 without crowdsec.**

Run:
```bash
ansible -i inventory/hosts.yaml vps-01 -m template \
  -a "src=configs/traefik/traefik.yml.j2 dest=/tmp/traefik.render.yml" \
  --connection=local -e enable_crowdsec=false -e cloudflare_proxied=true --check
```
Expected: no `crowdsec`/`bouncer` text would be rendered; `forwardedHeaders` trusted IPs still present. (If `--check` template is awkward, render locally with `ansible-playbook` dry-run in Task 17.)

- [ ] **Step 5: Commit.**

```bash
git add group_vars/all.yaml configs/traefik/traefik.yml.j2 configs/traefik/config.yml.j2
git commit -m "feat(traefik): gate crowdsec on enable_crowdsec, not cloudflare_proxied"
```

---

### Task 3: Tailscale role

**Files:**
- Create: `roles/tailscale/tasks/main.yaml`
- Create: `roles/tailscale/defaults/main.yaml`
- Modify: `vars/vault.yaml` (add `vault_tailscale_authkey`)

**Interfaces:**
- Consumes: `tailscale_hostname`, `tailscale_tags` (host_vars), `vault_tailscale_authkey` (vault).
- Produces: host joined to tailnet as `tag:vps-edge`, `tailscale0` interface up; fact `tailscale_ip` usable later.

- [ ] **Step 1: Add the auth key to vault.** `just decrypt`, add to `vars/vault.yaml`:

```yaml
vault_tailscale_authkey: "tskey-auth-REPLACE_ME"   # ephemeral, pre-authorized, tag:vps-edge
```
Then `just encrypt`. (Generate the key in the Tailscale admin console scoped to `tag:vps-edge`.)

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
    url: https://pkgs.tailscale.com/stable/debian/{{ ansible_distribution_release }}.noarmor.gpg
    dest: /usr/share/keyrings/tailscale-archive-keyring.gpg
    mode: "0644"

- name: Add Tailscale apt repo
  ansible.builtin.get_url:
    url: https://pkgs.tailscale.com/stable/debian/{{ ansible_distribution_release }}.tailscale-keyring.list
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
  changed_when: "'Success' in ts_up.stdout or ts_up.rc == 0"

- name: Get Tailscale IPv4
  ansible.builtin.command: tailscale ip -4
  register: ts_ip
  changed_when: false

- name: Store tailscale IP fact
  ansible.builtin.set_fact:
    tailscale_ip: "{{ ts_ip.stdout | trim }}"
```

> NOTE: Debian repo release detection uses `ansible_distribution_release` (e.g. `bookworm`). On Ubuntu the same Tailscale URL scheme works with the Ubuntu release codename — the task uses whichever the box reports. Verify apt-based in Task 15.

- [ ] **Step 4: Syntax-check the role via a no-op play.**

Run: `ansible-playbook -i inventory/hosts.yaml site.yaml --syntax-check`
Expected: no syntax errors (role referenced once Task 4 wires it in — run this after Task 4).

- [ ] **Step 5: Commit.**

```bash
git add roles/tailscale vars/vault.yaml
git commit -m "feat(tailscale): add role to join tailnet as tag:vps-edge (no egress)"
```

---

### Task 4: Hardening role (public-host firewall + sshd + fail2ban)

**Files:**
- Create: `roles/hardening/tasks/main.yaml`
- Create: `roles/hardening/templates/jail.local.j2`
- Create: `roles/hardening/handlers/main.yaml`

**Interfaces:**
- Consumes: `ansible_port` (break-glass SSH port), `tailscale_ip` (from Task 3), `cloudflare_ipv4`/`cloudflare_ipv6` (fetched at runtime), `mon_tailscale_ip` (var).
- Produces: nftables/ufw ruleset — inbound default-deny; 80/443 from CF ranges; metrics `9100,8082` from `mon` over tailscale; break-glass SSH; sshd hardened; fail2ban active.

- [ ] **Step 1: Create `roles/hardening/handlers/main.yaml`:**

```yaml
---
- name: Restart ssh service
  ansible.builtin.systemd:
    name: ssh
    state: restarted

- name: Restart ufw
  community.general.ufw:
    state: reloaded

- name: Restart fail2ban
  ansible.builtin.systemd:
    name: fail2ban
    state: restarted
```

- [ ] **Step 2: Create `roles/hardening/templates/jail.local.j2`:**

```ini
[sshd]
enabled = true
port = {{ ansible_port }}
maxretry = 4
findtime = 600
bantime = 3600
backend = systemd
```

- [ ] **Step 3: Create `roles/hardening/tasks/main.yaml`.** Applies only to public (non-local) hosts:

```yaml
---
- name: Harden sshd (key-only, no root)
  ansible.builtin.lineinfile:
    dest: /etc/ssh/sshd_config
    regexp: "{{ item.regexp }}"
    line: "{{ item.line }}"
    validate: "sshd -t -f %s"
  loop:
    - { regexp: "^.*PasswordAuthentication", line: "PasswordAuthentication no" }
    - { regexp: "^.*PermitRootLogin", line: "PermitRootLogin no" }
    - { regexp: "^.*Port ", line: "Port {{ ansible_port }}" }
  notify: Restart ssh service

- name: Fetch Cloudflare IPv4 ranges
  ansible.builtin.uri:
    url: https://www.cloudflare.com/ips-v4
    return_content: true
  register: cf_v4
  delegate_to: localhost
  become: false

- name: Fetch Cloudflare IPv6 ranges
  ansible.builtin.uri:
    url: https://www.cloudflare.com/ips-v6
    return_content: true
  register: cf_v6
  delegate_to: localhost
  become: false

- name: Set Cloudflare CIDR facts
  ansible.builtin.set_fact:
    cloudflare_cidrs: "{{ (cf_v4.content.splitlines() + cf_v6.content.splitlines()) | select | list }}"

- name: UFW default deny incoming
  community.general.ufw:
    direction: incoming
    policy: deny

- name: UFW default allow outgoing
  community.general.ufw:
    direction: outgoing
    policy: allow

- name: UFW allow break-glass SSH (rate-limited)
  community.general.ufw:
    rule: limit
    direction: in
    to_port: "{{ ansible_port }}"
    proto: tcp
  notify: Restart ufw

- name: UFW allow 80/443 from Cloudflare ranges only
  community.general.ufw:
    rule: allow
    direction: in
    src: "{{ item.0 }}"
    to_port: "{{ item.1 }}"
    proto: tcp
  loop: "{{ cloudflare_cidrs | product(['80', '443']) | list }}"
  loop_control:
    label: "{{ item.0 }}:{{ item.1 }}"
  notify: Restart ufw

- name: UFW allow metrics scrape from mon over tailscale
  community.general.ufw:
    rule: allow
    direction: in
    interface: tailscale0
    src: "{{ mon_tailscale_ip }}"
    to_port: "{{ item }}"
    proto: tcp
  loop: ["9100", "8082"]
  notify: Restart ufw

- name: UFW allow admin SSH over tailscale
  community.general.ufw:
    rule: allow
    direction: in
    interface: tailscale0
    to_port: "{{ ansible_port }}"
    proto: tcp
  notify: Restart ufw

- name: Enable UFW
  community.general.ufw:
    state: enabled
    logging: "on"

- name: Deploy fail2ban jail
  ansible.builtin.template:
    src: jail.local.j2
    dest: /etc/fail2ban/jail.local
    mode: "0644"
  notify: Restart fail2ban

- name: Enable fail2ban
  ansible.builtin.systemd:
    name: fail2ban
    state: started
    enabled: true
```

- [ ] **Step 4: Add `mon_tailscale_ip` to `group_vars/all.yaml`** (used by the metrics rule):

```yaml
mon_tailscale_ip: "100.64.0.10"   # PLACEHOLDER: mon's tailscale IP; confirm in Task 18
```

- [ ] **Step 5: Syntax-check.**

Run: `ansible-playbook -i inventory/hosts.yaml site.yaml --syntax-check`
Expected: no errors.

- [ ] **Step 6: Commit.**

```bash
git add roles/hardening group_vars/all.yaml
git commit -m "feat(hardening): public-host firewall (CF-only 80/443, tailscale metrics), sshd, fail2ban"
```

---

### Task 5: Add the `vps-01` play to `site.yaml`

**Files:**
- Modify: `site.yaml`

**Interfaces:**
- Consumes: roles `grog.package`, `base`, `docker`, `tailscale`, `hardening`, `services`.
- Produces: a dedicated play so `just run-machine vps-01` provisions everything; legacy `cloud` play stays for `external-01`.

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
    - role: hardening
    - role: services
      tags: configs
```

- [ ] **Step 2: Exclude `vps-01` from the legacy `cloud` play** so it isn't double-run. Change that play's `hosts: cloud` to `hosts: external-01` (until decommission, when the whole play is removed).

- [ ] **Step 3: Verify play list.**

Run: `ansible-playbook -i inventory/hosts.yaml site.yaml --list-hosts --limit vps-01`
Expected: only the new play matches `vps-01`.

- [ ] **Step 4: Commit.**

```bash
git add site.yaml
git commit -m "feat(vps-01): dedicated site.yaml play (base+docker+tailscale+hardening+services)"
```

---

### Task 6: Docker daemon log rotation + journald cap

**Files:**
- Modify: `roles/docker/tasks/main.yaml` (or `roles/base`) — add `/etc/docker/daemon.json`
- Modify: `group_vars/all.yaml` — log size defaults

**Interfaces:**
- Produces: global container log caps; bounded journald.

- [ ] **Step 1: Add defaults** to `group_vars/all.yaml`:

```yaml
docker_log_max_size: "10m"
docker_log_max_file: "3"
journald_system_max_use: "500M"
```

- [ ] **Step 2: Add daemon.json task** to `roles/docker/tasks/main.yaml`:

```yaml
- name: Configure Docker daemon log rotation
  ansible.builtin.copy:
    dest: /etc/docker/daemon.json
    mode: "0644"
    content: |
      {
        "log-driver": "json-file",
        "log-opts": { "max-size": "{{ docker_log_max_size }}", "max-file": "{{ docker_log_max_file }}" },
        "live-restore": true
      }
  notify: Restart docker
```

Ensure a `Restart docker` handler exists in the docker role (add if missing):

```yaml
- name: Restart docker
  ansible.builtin.systemd:
    name: docker
    state: restarted
```

- [ ] **Step 3: Cap journald** — add to `roles/base/tasks/main.yaml`:

```yaml
- name: Cap journald disk usage
  ansible.builtin.lineinfile:
    path: /etc/systemd/journald.conf
    regexp: "^#?SystemMaxUse="
    line: "SystemMaxUse={{ journald_system_max_use }}"
  notify: Restart journald
```

Add handler to `roles/base/handlers/main.yaml`:

```yaml
- name: Restart journald
  ansible.builtin.systemd:
    name: systemd-journald
    state: restarted
```

- [ ] **Step 4: Syntax-check + commit.**

Run: `ansible-playbook -i inventory/hosts.yaml site.yaml --syntax-check`

```bash
git add roles/docker roles/base group_vars/all.yaml
git commit -m "feat(docker): global json-file log caps + journald SystemMaxUse"
```

---

### Task 7: docker-socket-proxy service + route Traefik/Dozzle through it

**Files:**
- Create: `configs/docker-socket-proxy/docker-compose.yaml`
- Create: `configs/docker-socket-proxy/.env.st`
- Modify: `configs/traefik/docker-compose.yaml`
- Modify: `configs/traefik/traefik.yml.j2`
- Modify: `configs/dozzle/docker-compose.yaml`

**Interfaces:**
- Produces: `docker-socket-proxy` on the `proxy` network exposing a read-only Docker API at `tcp://docker-socket-proxy:2375`. Traefik and Dozzle consume it instead of mounting the socket.

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
      CONTAINERS: 1        # dozzle + traefik need container listing
      IMAGES: 1
      NETWORKS: 1
      SERVICES: 0
      TASKS: 0
      POST: 0              # read-only: deny all write endpoints
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

- [ ] **Step 3: Point Traefik's Docker provider at the proxy.** In `configs/traefik/traefik.yml.j2` change:

```yaml
providers:
  docker:
    endpoint: "tcp://docker-socket-proxy:2375"
    exposedByDefault: false
```

- [ ] **Step 4: Remove Traefik's direct socket mount** in `configs/traefik/docker-compose.yaml` — delete the line:

```yaml
      - /var/run/docker.sock:/var/run/docker.sock:ro
```

(Traefik reaches the proxy over the `proxy` network; it already joins it.)

- [ ] **Step 5: Point Dozzle at the proxy.** In `configs/dozzle/docker-compose.yaml`, replace the socket volume with a remote host env and drop the mount:

```yaml
    environment:
      - TZ=${TZ}
      - DOZZLE_AUTH_PROVIDER=none
      - DOZZLE_LEVEL=info
      - DOZZLE_REMOTE_HOST=tcp://docker-socket-proxy:2375
```
Remove:
```yaml
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
```

> ORDERING: `docker-socket-proxy` is first in `services_configs` (Task 1) so it starts before Traefik/Dozzle.

- [ ] **Step 6: Commit.**

```bash
git add configs/docker-socket-proxy configs/traefik/docker-compose.yaml configs/traefik/traefik.yml.j2 configs/dozzle/docker-compose.yaml
git commit -m "feat(security): read-only docker-socket-proxy for traefik and dozzle"
```

---

### Task 8: Authentik forward-auth middleware + protect apps

**Files:**
- Modify: `configs/traefik/config.yml.j2` (add `authentik` middleware)
- Modify: `configs/dozzle/docker-compose.yaml`
- Modify: `configs/freshrss/docker-compose.yaml`
- Modify: `configs/wallabag/docker-compose.yaml`
- Modify: `configs/traefik/docker-compose.yaml` (dashboard uses authentik, not basicauth)

**Interfaces:**
- Consumes: Authentik embedded outpost at `authentik-server:9000`.
- Produces: a file-provider middleware `authentik@file` referenced by protected routers.

- [ ] **Step 1: Add the middleware** to `configs/traefik/config.yml.j2` under `http: middlewares:` (create the key if the crowdsec block is gated off):

```jinja
http:
  middlewares:
{% if enable_crowdsec %}
    crowdsec:
      # ... existing crowdsec block ...
{% endif %}
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
```

Also add a router so the outpost callback path is reachable (Authentik docs pattern) — add under `routers:`:

```jinja
    authentik-outpost:
      rule: "HostRegexp(`{subdomain:[a-z0-9-]+}.{{ full_domain }}`) && PathPrefix(`/outpost.goauthentik.io/`)"
      entryPoints:
        - https
      service: authentik@file
      tls: {}
```

And a matching service:

```jinja
http:
  services:
    authentik:
      loadBalancer:
        servers:
          - url: "http://authentik-server:9000/"
```

- [ ] **Step 2: Protect Dozzle.** In `configs/dozzle/docker-compose.yaml` replace `traefik-auth@docker` with `authentik@file`:

```yaml
      - "traefik.http.routers.dozzle.middlewares=authentik@file"
```

- [ ] **Step 3: Protect FreshRSS.** In `configs/freshrss/docker-compose.yaml`, on the HTTPS router labels add:

```yaml
      - "traefik.http.routers.freshrss.middlewares=authentik@file"
```
(Match the actual router name in that file; keep any existing middleware chain by comma-joining.)

- [ ] **Step 4: Protect Wallabag.** In `configs/wallabag/docker-compose.yaml`, on the HTTPS router labels add:

```yaml
      - "traefik.http.routers.wallabag.middlewares=authentik@file"
```

- [ ] **Step 5: Switch Traefik dashboard to Authentik.** In `configs/traefik/docker-compose.yaml`, replace the `traefik-auth` basicauth middleware reference on `traefik-secure` with `authentik@file`:

```yaml
      - "traefik.http.routers.traefik-secure.middlewares=authentik@file"
```
Remove the now-unused `traefik-auth.basicauth.users` label.

- [ ] **Step 6: Commit.**

```bash
git add configs/traefik configs/dozzle/docker-compose.yaml configs/freshrss/docker-compose.yaml configs/wallabag/docker-compose.yaml
git commit -m "feat(sso): authentik forward-auth for dozzle/freshrss/wallabag/traefik-dashboard"
```

---

### Task 9: Authentik secrets in vault + `.env.st`

**Files:**
- Modify: `vars/vault.yaml`
- Verify: `configs/authentik/.env.st`

**Interfaces:**
- Produces: `PG_PASS`, `AUTHENTIK_SECRET_KEY`, `PG_USER`, `PG_DB` available to the authentik compose via templated `.env`.

- [ ] **Step 1: Inspect `configs/authentik/.env.st`** and confirm the variable names it references (`PG_PASS`, `PG_USER`, `PG_DB`, `AUTHENTIK_SECRET_KEY`, `FULL_DOMAIN`, `TZ`). Ensure each maps to a vault or group var.

- [ ] **Step 2: Add secrets to vault.** `just decrypt`, add:

```yaml
vault_authentik_pg_pass: "REPLACE_STRONG_PW"
vault_authentik_secret_key: "REPLACE_50_CHAR_RANDOM"   # openssl rand -base64 60
```
`just encrypt`.

- [ ] **Step 3: Ensure `.env.st` binds them**, e.g.:

```jinja
PG_PASS={{ vault_authentik_pg_pass }}
PG_USER=authentik
PG_DB=authentik
AUTHENTIK_SECRET_KEY={{ vault_authentik_secret_key }}
FULL_DOMAIN={{ full_domain }}
TZ={{ default_timezone }}
```

- [ ] **Step 4: Verify no plaintext secret leaks.**

Run: `git grep -n "REPLACE_" -- vars/ || true` and confirm `vars/vault.yaml` is encrypted (`head -1 vars/vault.yaml` shows `$ANSIBLE_VAULT`).

- [ ] **Step 5: Commit.**

```bash
git add vars/vault.yaml configs/authentik/.env.st
git commit -m "feat(authentik): vault secrets and env bindings"
```

---

### Task 10: Make `promtail` conditional in monitoring-client

**Files:**
- Modify: `configs/monitoring-client/docker-compose.yaml`

**Interfaces:**
- Consumes: `monitoring_client_promtail` (host var; `false` for vps-01, default `true`).
- Produces: vps-01 runs `node-exporter` + `cadvisor` only (no log egress).

- [ ] **Step 1: Convert compose to a template.** Rename to `docker-compose.yaml.j2` is invasive; instead gate promtail with a compose `profiles` toggle driven by env. Add to the `promtail` service:

```yaml
  promtail:
    profiles: ["${PROMTAIL_PROFILE:-logs}"]
    # ...unchanged...
```

- [ ] **Step 2: Drive the profile from `.env.st`.** In `configs/monitoring-client/.env.st` add:

```jinja
PROMTAIL_PROFILE={{ 'logs' if (monitoring_client_promtail | default(true)) else 'disabled' }}
```

With `monitoring_client_promtail: false` (vps-01 host_vars), the profile becomes `disabled`, so `docker compose up` (no `--profile disabled`) will NOT start promtail. Existing hosts default to `logs` and are unchanged.

- [ ] **Step 3: Add the default** to `group_vars/all.yaml`:

```yaml
monitoring_client_promtail: true
```

- [ ] **Step 4: Verify vps-01 renders `disabled`.**

Run: `ansible -i inventory/hosts.yaml vps-01 -m debug -a "msg={{ 'logs' if (monitoring_client_promtail | default(true)) else 'disabled' }}" --connection=local`
Expected: `disabled`.

- [ ] **Step 5: Commit.**

```bash
git add configs/monitoring-client group_vars/all.yaml
git commit -m "feat(monitoring-client): make promtail optional; disable on vps-01 (no log egress)"
```

---

### Task 11: Traefik log rotation + secrets dir hardening

**Files:**
- Create: `roles/hardening/templates/logrotate-traefik.j2`
- Modify: `roles/hardening/tasks/main.yaml`
- Modify: `roles/services/tasks/main.yaml` (service dir 0700)

**Interfaces:**
- Produces: `/etc/logrotate.d/traefik`; service directories `0700`.

- [ ] **Step 1: Create `roles/hardening/templates/logrotate-traefik.j2`:**

```jinja
{{ app_folder_root }}/traefik/logs/*.log {
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

- [ ] **Step 2: Install it** — add to `roles/hardening/tasks/main.yaml`:

```yaml
- name: Install Traefik logrotate config
  ansible.builtin.template:
    src: logrotate-traefik.j2
    dest: /etc/logrotate.d/traefik
    mode: "0644"
```

- [ ] **Step 3: Tighten service dir perms.** In `roles/services/tasks/main.yaml`, change the "Make sure the service folder exists" task `mode: "0755"` → `mode: "0700"`. (This affects all hosts; verify existing hosts still work — dirs owned by `main_username`, containers run as same UID, so 0700 is safe.)

- [ ] **Step 4: Verify logrotate config is valid** (after deploy, Task 17):

Run: `ssh vps-01 sudo logrotate -d /etc/logrotate.d/traefik`
Expected: dry-run prints rotation plan, no errors.

- [ ] **Step 5: Commit.**

```bash
git add roles/hardening roles/services/tasks/main.yaml
git commit -m "feat(hardening): traefik logrotate + 0700 service dirs"
```

---

### Task 12: Nightly `pg_dump` backup timer

**Files:**
- Create: `roles/hardening/templates/pg-backup.sh.j2`
- Create: `roles/hardening/templates/pg-backup.service.j2`
- Create: `roles/hardening/templates/pg-backup.timer.j2`
- Modify: `roles/hardening/tasks/main.yaml`

**Interfaces:**
- Produces: systemd timer dumping Authentik/Wallabag/FreshRSS Postgres containers nightly into `/opt/stacks/backups`, retained 7 days; captured by OVH snapshots.

- [ ] **Step 1: Create `roles/hardening/templates/pg-backup.sh.j2`:**

```bash
#!/usr/bin/env bash
set -euo pipefail
BACKUP_DIR="{{ app_folder_root }}/backups"
mkdir -p "$BACKUP_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
for c in authentik-postgresql {{ wallabag_db_container | default('wallabag-db') }}; do
  if docker ps --format '{{ "{{.Names}}" }}' | grep -q "^${c}$"; then
    docker exec "$c" pg_dumpall -U postgres 2>/dev/null \
      | gzip > "$BACKUP_DIR/${c}-${STAMP}.sql.gz" || true
  fi
done
# prune older than 7 days
find "$BACKUP_DIR" -name '*.sql.gz' -mtime +7 -delete
```

- [ ] **Step 2: Create `roles/hardening/templates/pg-backup.service.j2`:**

```ini
[Unit]
Description=Nightly Postgres logical backup

[Service]
Type=oneshot
ExecStart={{ app_folder_root }}/backups/pg-backup.sh
```

- [ ] **Step 3: Create `roles/hardening/templates/pg-backup.timer.j2`:**

```ini
[Unit]
Description=Run pg-backup nightly

[Timer]
OnCalendar=*-*-* 03:30:00
Persistent=true

[Install]
WantedBy=timers.target
```

- [ ] **Step 4: Wire tasks** into `roles/hardening/tasks/main.yaml`:

```yaml
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
  loop:
    - pg-backup.service
    - pg-backup.timer

- name: Enable pg-backup timer
  ansible.builtin.systemd:
    name: pg-backup.timer
    state: started
    enabled: true
    daemon_reload: true
```

- [ ] **Step 5: Verify (post-deploy, Task 17).**

Run: `ssh vps-01 'sudo systemctl start pg-backup.service && ls -la /opt/stacks/backups'`
Expected: `.sql.gz` files present.

- [ ] **Step 6: Commit.**

```bash
git add roles/hardening
git commit -m "feat(backup): nightly pg_dump systemd timer (captured by OVH snapshots)"
```

---

## Phase B — Provision & bootstrap (requires the live VPS)

### Task 13: First contact + admin user

**Files:** none (operational).

**Interfaces:**
- Produces: `dinos` admin user with SSH key + passwordless sudo; verified apt-based OS.

- [ ] **Step 1: Confirm OS is apt-based.**

Run: `ssh <ovh-default-user>@<vps-public-ip> 'cat /etc/os-release'`
Expected: `ID=debian` or `ID=ubuntu`. If not apt-based, STOP and revisit roles.

- [ ] **Step 2: Create admin user + key + sudo** (run as the OVH default/root):

```bash
ssh <ovh-default-user>@<vps-public-ip> '
  sudo useradd -m -s /bin/bash -G sudo dinos &&
  sudo mkdir -p /home/dinos/.ssh && sudo chmod 700 /home/dinos/.ssh'
ssh-copy-id -i ~/.ssh/id_ed25519.pub dinos@<vps-public-ip>   # or push key manually
ssh <ovh-default-user>@<vps-public-ip> '
  echo "dinos ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/dinos &&
  sudo chmod 440 /etc/sudoers.d/dinos'
```

- [ ] **Step 3: Verify key login as `dinos`.**

Run: `ssh dinos@<vps-public-ip> 'sudo whoami'`
Expected: `root` (passwordless sudo works).

- [ ] **Step 4: Temporarily point inventory at the public IP on port 22** for the first Ansible run: set `vps-01.ansible_host: <public-ip>`, `ansible_port: 22` in `inventory/hosts.yaml`. (No commit yet — reverted in Task 16.)

---

### Task 14: Base + Docker + Tailscale bring-up

**Files:** none (operational; uses roles from Phase A).

**Interfaces:**
- Consumes: Phase A roles. Produces: hardened host on tailnet; `proxy` docker network.

- [ ] **Step 1: Ensure the `proxy` docker network exists.** Confirm whether an existing role creates it; if not, add a one-off:

Run: `ssh dinos@<vps-public-ip> 'docker network create proxy || true'`
Expected: network id or "already exists".

- [ ] **Step 2: Run base + docker + tailscale only** (skip services to bring the tunnel up before locking down SSH):

Run: `ansible-playbook -i inventory/hosts.yaml site.yaml --limit vps-01 --tags untagged --skip-tags configs`
Expected: base packages installed, docker running, `tailscale up` succeeds, `tailscale_ip` fact set. Note the printed tailscale IP.

- [ ] **Step 3: Verify tailnet + isolation.**

Run:
```bash
tailscale status | grep vps-01              # from your admin machine
ssh dinos@<vps-tailscale-ip> 'tailscale ip -4'
```
Expected: `vps-01` appears with `tag:vps-edge`; reachable over tailscale.

- [ ] **Step 4: Apply the tailnet ACL** in the Tailscale admin console (see design §4):

```jsonc
"tagOwners": { "tag:vps-edge": ["autogroup:admin"] },
"acls": [
  { "action": "accept", "src": ["tag:mon"],        "dst": ["tag:vps-edge:9100,8082"] },
  { "action": "accept", "src": ["<your-admin-device>"], "dst": ["tag:vps-edge:<ssh-port>"] }
  // vps-edge is NOT a src in any rule → cannot initiate to other nodes
]
```

- [ ] **Step 5: Prove egress is blocked.**

Run: `ssh dinos@<vps-tailscale-ip> 'tailscale ping mon || echo BLOCKED-AS-EXPECTED'`
Expected: ping fails / `BLOCKED-AS-EXPECTED` (VPS cannot reach other nodes).

---

### Task 15: Lock down SSH + switch inventory to Tailscale

**Files:**
- Modify: `inventory/hosts.yaml`

**Interfaces:**
- Produces: SSH on custom port; inventory pointed at tailscale IP for day-2.

- [ ] **Step 1: Run the hardening role** (sets custom SSH port, firewall, fail2ban):

Run: `ansible-playbook -i inventory/hosts.yaml site.yaml --limit vps-01 --tags untagged --skip-tags configs`
(hardening is in the role list; sshd Port becomes `{{ ansible_port }}` = 4322.)

- [ ] **Step 2: Set inventory to tailscale IP + custom port** in `inventory/hosts.yaml`:

```yaml
        vps-01:
          ansible_host: <vps-tailscale-ip>
          ansible_port: 4322
          ansible_user: dinos
```

- [ ] **Step 3: Verify Ansible reaches it over tailscale on the new port.**

Run: `ansible -i inventory/hosts.yaml vps-01 -m ping`
Expected: `pong`.

- [ ] **Step 4: Verify public SSH break-glass works but is rate-limited, and 80/443 blocked from non-CF.**

Run:
```bash
nc -vz -w5 <vps-public-ip> 4322          # open (break-glass)
nc -vz -w5 <vps-public-ip> 443 && echo "OPEN (should be refused from non-CF)"
```
Expected: 4322 open; 443 refused/timeout from your (non-Cloudflare) IP.

- [ ] **Step 5: Commit inventory.**

```bash
git add inventory/hosts.yaml
git commit -m "chore(vps-01): point inventory at tailscale IP + custom ssh port"
```

---

### Task 16: Deploy the full service stack

**Files:** none (operational).

**Interfaces:**
- Consumes: everything from Phase A. Produces: running stack (minus data).

- [ ] **Step 1: Deploy services.**

Run: `just run-machine vps-01`
Expected: all containers up: docker-socket-proxy, traefik, authentik-{postgresql,redis,server,worker}, littlelink, freshrss, wallabag, node-exporter, cadvisor, dozzle. No promtail.

- [ ] **Step 2: Verify container health.**

Run: `ssh vps-01 'docker ps --format "{{ "{{.Names}}\t{{.Status}}" }}"'`
Expected: all `Up`/`healthy`; `promtail` absent.

- [ ] **Step 3: Verify Traefik got routes via the socket proxy (no direct socket mount).**

Run: `ssh vps-01 'docker inspect traefik --format "{{ "{{ .HostConfig.Binds }}" }}"'`
Expected: no `/var/run/docker.sock` bind.

- [ ] **Step 4: Verify TLS issued** (DNS-01) for a test host:

Run: `curl -sI https://littlelink.dinos.sh` (once DNS points here in Phase C; pre-cutover use `--resolve littlelink.dinos.sh:443:<vps-public-ip>`)
Expected: `HTTP/2 200`, valid Let's Encrypt cert.

---

### Task 17: Configure Authentik (providers, apps, outpost)

**Files:** none (Authentik UI; documented steps).

**Interfaces:**
- Produces: forward-auth working for dozzle/freshrss/wallabag/traefik-dashboard.

- [ ] **Step 1: Bootstrap admin.** Browse `https://auth.dinos.sh/if/flow/initial-setup/` (use `--resolve` pre-cutover). Set the admin (akadmin) password.

- [ ] **Step 2: Create a Proxy Provider (forward-auth, single application)** for each protected host, or one domain-level forward-auth provider covering `*.dinos.sh`. External host = the app URL; mode = "Forward auth (single application)" or "(domain level)".

- [ ] **Step 3: Bind the embedded outpost** to the providers (Applications → Outposts → authentik Embedded Outpost → add providers).

- [ ] **Step 4: Create Applications** for freshrss, wallabag, dozzle, traefik-dashboard, each linked to its provider, with an access policy (your user/group).

- [ ] **Step 5: Verify forward-auth.**

Run (browser): visit `https://dozzle.dinos.sh` → redirected to Authentik login → after auth, Dozzle loads.
Expected: unauthenticated access is blocked; authenticated passes.

---

### Task 18: End-to-end verification

**Files:** none.

- [ ] **Step 1: Metrics scrape from mon.** On `mon`, confirm Prometheus targets `vps-01` node-exporter/cadvisor over tailscale are `UP`.
- [ ] **Step 2: Isolation.** `ssh vps-01 'curl -m5 http://<mon-tailscale-ip>:3100/ready || echo BLOCKED'` → `BLOCKED` (no Loki egress).
- [ ] **Step 3: Firewall.** From a non-CF IP: `curl -m5 https://<vps-public-ip>` → refused; via CF hostname → 200.
- [ ] **Step 4: Logs local.** `ssh vps-01 'docker logs --tail 5 traefik'` and Dozzle UI both show logs; nothing in central Loki for vps-01.
- [ ] **Step 5: Backups.** `ssh vps-01 'sudo systemctl start pg-backup.service && ls /opt/stacks/backups'` → dumps exist.
- [ ] **Step 6: Log caps.** `ssh vps-01 'cat /etc/docker/daemon.json'` shows `max-size 10m`.

---

## Phase C — Data migration & cutover

### Task 19: Migrate Wallabag data

**Files:** none (operational).

**Interfaces:**
- Consumes: old `external-01` Wallabag volumes/DB. Produces: restored Wallabag on vps-01.

- [ ] **Step 1: Enable OVH provider backups/snapshots** in the OVH panel for `vps-01` (one-time). Confirm a snapshot completes.

- [ ] **Step 2: Quiesce old Wallabag.** On `external-01`: `docker compose -f /opt/stacks/wallabag/docker-compose.yaml stop`.

- [ ] **Step 3: Dump the DB and archive images/data** on `external-01`:

```bash
docker exec wallabag-db pg_dumpall -U postgres | gzip > /tmp/wallabag.sql.gz   # adjust container/engine
tar czf /tmp/wallabag-data.tgz -C /opt/stacks/wallabag images data
```
(If Wallabag uses SQLite/MariaDB here, adjust dump accordingly — verify engine in `configs/wallabag/docker-compose.yaml` first.)

- [ ] **Step 4: Transfer to vps-01** (via your admin machine, since VPS can't initiate to the old VM):

```bash
scp external-01:/tmp/wallabag.sql.gz external-01:/tmp/wallabag-data.tgz /tmp/
scp /tmp/wallabag.sql.gz /tmp/wallabag-data.tgz vps-01:/tmp/
```

- [ ] **Step 5: Restore on vps-01.** Stop wallabag app container, restore volumes + DB, restart:

```bash
ssh vps-01 '
  cd /opt/stacks/wallabag &&
  tar xzf /tmp/wallabag-data.tgz -C /opt/stacks/wallabag &&
  gunzip -c /tmp/wallabag.sql.gz | docker exec -i wallabag-db psql -U postgres'
ssh vps-01 'docker compose -f /opt/stacks/wallabag/docker-compose.yaml up -d'
```

- [ ] **Step 6: Verify.** Log into `https://wallabag.dinos.sh` (via `--resolve` pre-cutover); confirm entry count matches old instance.

---

### Task 20: Migrate FreshRSS data

**Files:** none (operational).

- [ ] **Step 1: Export on old host.** Prefer DB migration; fallback OPML. On `external-01`:

```bash
docker exec freshrss-db pg_dumpall -U postgres | gzip > /tmp/freshrss.sql.gz   # if postgres
# fallback: export OPML from FreshRSS UI (Subscription management → Export)
```
(Verify FreshRSS storage engine in `configs/freshrss/docker-compose.yaml`; SQLite → copy the `data/` volume instead.)

- [ ] **Step 2: Transfer via admin machine** (same relay pattern as Task 19 Step 4).

- [ ] **Step 3: Restore on vps-01** (DB import or OPML import via UI after creating the user).

- [ ] **Step 4: Verify feeds present** at `https://freshrss.dinos.sh`.

---

### Task 21: DNS cutover + decommission

**Files:**
- Modify: `inventory/hosts.yaml`, `site.yaml` (remove `external-01`)

- [ ] **Step 1: Pre-lower TTL** (~24h earlier) on all affected Cloudflare records.

- [ ] **Step 2: Flip DNS.** In Cloudflare, replace tunnel CNAMEs with **proxied A/AAAA** records for each `*.dinos.sh` host → `vps-01` public IP (orange cloud ON). Records: `littlelink`(root/links), `freshrss`, `wallabag`, `dozzle`, `auth`, `traefik-dashboard`, `node-exporter`, `cadvisor` (or keep exporters internal-only).

- [ ] **Step 3: Smoke test each hostname** without `--resolve`:

```bash
for h in links freshrss wallabag dozzle auth traefik-dashboard; do
  echo "== $h =="; curl -sI https://$h.dinos.sh | head -1
done
```
Expected: all `200`/`302`(auth redirect); certs valid; served by vps-01.

- [ ] **Step 4: Decommission old VM.** Power off `external-01`; after confidence, remove from `inventory/hosts.yaml` and delete the legacy `Setup cloud servers`/`hosts: external-01` play from `site.yaml`. Optionally `git rm host_vars/external-01.yaml`.

- [ ] **Step 5: Commit.**

```bash
git add inventory/hosts.yaml site.yaml
git rm host_vars/external-01.yaml
git commit -m "chore: decommission external-01 after vps-01 cutover"
```

- [ ] **Step 6: Final backup verification.** Confirm OVH snapshot + `pg_dump` timer have run at least once post-cutover.

---

## Self-Review Notes

- **Spec coverage:** §1 identity → Task 1; §2 exposure/CF firewall → Task 4; §3 SSH/bootstrap → Tasks 13–15; §4 tailscale ACL + promtail drop → Tasks 3,10,14; §5 socket-proxy/hardening → Tasks 6,7,11; §6 hardened .env → Task 11 (0700) + role default 0600; §7 authentik SSO → Tasks 8,9,17; §8 data migration + backups → Tasks 12,19,20; §9 log rotation → Tasks 6,11; §10 cutover → Task 21; §11 repo integration/testing → Tasks 5,18.
- **Open items carried from spec §12:** monitoring-client push→resolved (promtail dropped, exporters pull); OS apt-check → Task 13 Step 1; break-glass port (4322) and admin device identity → Tasks 15/14 Step 4.
- **Assumptions to verify during execution:** Wallabag/FreshRSS DB engines (Tasks 19–20 check the compose before dumping); existence of a `proxy` network creation step (Task 14 Step 1 guards it); `mon`/admin tailscale IPs (placeholders in Task 4/14).
