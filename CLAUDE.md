# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

All operations use `just` command:

### Core Deployment

- `just run` - Deploy all services except DNS to all hosts
- `just run-machine <hostname>` - Deploy to specific machine (e.g., mon, infra, apps, mqtt)
- `just run-ext` - Deploy only to cloud/external servers
- `just config-only <hostname>` - Deploy only configurations without service restarts

### DNS Management

- `just update-dns` - Update Pi-hole configurations on both DNS servers

### Vault & Security

- `just encrypt` / `just decrypt` - Manage Ansible Vault encryption for vars/vault.yaml
- `just setup-ssh <hostname>` - Configure SSH port changes

### Dependencies

- `just ansible-reqs` - Install Ansible Galaxy requirements
- `just python-reqs` - Install Python dependencies

### Power Management (UPS)

- `just nut-server` - Configure UPS server on pve1
- `just nut-client` - Configure UPS clients on pve2

### Kubernetes Cluster

- `just cluster-up` - Deploy K3s cluster
- `just cluster-down` - Tear down K3s cluster

### Testing

- `just test-new-roles` - Test roles on designated test hosts

### Utilities

- `just new-config <service-name>` - Generate new service config from template

## Architecture

### Infrastructure Layout

This manages a home lab with 4 Proxmox VMs (mon, infra, apps, mqtt), 2 Proxmox hosts (pve1, pve2), dual Pi-hole DNS servers, and an external cloud server. Local services deploy to `/opt/knxcloud/` using the knxcloud.io domain; external services deploy to `/opt/stacks/` using the dinos.sh domain.

### Host Inventory

- **proxmox_vms**: mon (monitoring), infra (infrastructure), apps (applications), mqtt (message broker)
- **piholes**: pihole-primary, pihole-backup (DNS redundancy)
- **cloud**: external-01 (cloud server)
- **proxmox_hosts**: pve1, pve2 (Proxmox nodes for UPS management)

### Service Management

Services are controlled via the `services_configs` list in host_vars (e.g., `host_vars/mon.yaml`). Each service has:

- A Docker Compose config in `/configs/<service>/docker-compose.yaml`
- An `.env.st` file (Jinja2 template) for environment variables
- Optional additional config files (`.j2` for templated, plain for direct copy)

Services are deployed using the `services` role, which:

1. Creates the service directory at `/opt/knxcloud/<service>/`
2. Templates `.env.st` → `.env` with variable substitution
3. Copies non-template files and templates `.j2` files
4. Runs docker-compose up

The older `docker_services` role is deprecated.

### Key Infrastructure Components

- **Monitoring Stack**: Prometheus, Grafana, Loki, Alertmanager on mon
- **Reverse Proxy**: Traefik with Cloudflare ACME SSL on every host
- **Identity**: Authentik (config exists in `/configs/authentik/` but not deployed)
- **DNS**: Dual Pi-hole instances for redundancy (192.168.1.202 primary, 192.168.3.254 backup)
- **Power**: Network UPS Tools (NUT) for graceful shutdowns
- **Kubernetes**: Optional K3s cluster support

### Service URL Patterns

- Local VMs: `<service>.<hostname>.knxcloud.io` (e.g. `grafana.mon.knxcloud.io`)
- External cloud: `<service>.dinos.sh` (e.g. `freshrss.dinos.sh`)
- Traefik dashboards: `traefik-dashboard.<hostname>.knxcloud.io` (basic auth protected)

### Services by Host

**mon** (monitoring): traefik, prometheus (`prometheus.mon.knxcloud.io`), grafana (`grafana.mon.knxcloud.io`), loki, alertmanager, pushgateway, portainer (`portainer.mon.knxcloud.io`), uptime-kuma (`uptime-kuma.mon.knxcloud.io`), glowprom, monitoring-client

**infra** (infrastructure): traefik, op-connect (1Password API `opapi.infra.knxcloud.io` + sync `opsync.infra.knxcloud.io`), monitoring-client

**apps** (applications): traefik, calibre (`calibre.apps.knxcloud.io`), audiobookshelf (`abs.apps.knxcloud.io`), mealie (`mealie.apps.knxcloud.io`), stirlingpdf (`pdf.apps.knxcloud.io`), atuin (`atuin.apps.knxcloud.io`), homepage (`home.apps.knxcloud.io`), monitoring-client
- Smart home (commented out, configs exist): scrypted, homebridge, zigbee2mqtt (z2m-main, z2m-mancave)

**mqtt** (broker): traefik, mosquitto (1883/9001), monitoring-client

**external-01** (dinos.sh, Cloudflare-proxied): traefik, cloudflared, littlelink (`links.dinos.sh`), karakeep (`hoarder.dinos.sh`), freshrss (`freshrss.dinos.sh`), linkwarden (`linkwarden.dinos.sh`), crowdsec, monitoring-client
- Commented out (configs exist): ntfy (`notify.dinos.sh`), wallabag (`read.dinos.sh`)

**pve1 / pve2**: Proxmox hypervisors at `pve1.knxcloud.io:8006` / `pve2.knxcloud.io:8006`

### Variable Structure

- `group_vars/all.yaml` - Global settings, container versions, network config
- `group_vars/cloud.yaml` - Cloud-specific settings (is_local_vm: false)
- `group_vars/piholes.yaml` - DNS entries and dnsmasq configuration
- `host_vars/<hostname>.yaml` - Host-specific service assignments via `services_configs`
- `vars/vault.yaml` - Encrypted secrets (always keep encrypted in commits)

### Container Version Management

Container versions are managed in two places:

- Newer services have versions directly in docker-compose.yaml files in `/configs/`
- Renovate is configured to automatically update container versions

### Adding a New Service

1. Run `just new-config <service-name>` to create from template
2. Edit `/configs/<service>/docker-compose.yaml` and `.env.st`
3. Add the service to the appropriate `host_vars/<hostname>.yaml` under `services_configs`
4. Deploy with `just run-machine <hostname>`
