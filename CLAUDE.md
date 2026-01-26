# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

All operations use `task` command (Go Task):

### Core Deployment

- `task run` - Deploy all services except DNS to all hosts
- `task run-machine -- <hostname>` - Deploy to specific machine (e.g., mon, infra, apps, mqtt)
- `task run-ext` - Deploy only to cloud/external servers
- `task config-only -- <hostname>` - Deploy only configurations without service restarts

### DNS Management

- `task update-dns` - Update Pi-hole configurations on both DNS servers

### Vault & Security

- `task encrypt` / `task decrypt` - Manage Ansible Vault encryption for vars/vault.yaml
- `task setup-ssh -- <hostname>` - Configure SSH port changes

### Dependencies

- `task ansible-reqs` - Install Ansible Galaxy requirements
- `task python-reqs` - Install Python dependencies

### Power Management (UPS)

- `task nut-server` - Configure UPS server on pve1
- `task nut-client` - Configure UPS clients on pve2

### Kubernetes Cluster

- `task cluster-up` - Deploy K3s cluster
- `task cluster-down` - Tear down K3s cluster

### Testing

- `task test-new-roles` - Test roles on designated test hosts

### Utilities

- `task new-config -- <service-name>` - Generate new service config from template

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
- **Identity**: Authentik for SSO
- **DNS**: Dual Pi-hole instances for redundancy
- **Power**: Network UPS Tools (NUT) for graceful shutdowns
- **Kubernetes**: Optional K3s cluster support

### Variable Structure

- `group_vars/all.yaml` - Global settings, container versions, network config
- `group_vars/cloud.yaml` - Cloud-specific settings (is_local_vm: false)
- `group_vars/piholes.yaml` - DNS entries and dnsmasq configuration
- `host_vars/<hostname>.yaml` - Host-specific service assignments via `services_configs`
- `vars/vault.yaml` - Encrypted secrets (always keep encrypted in commits)

### Container Version Management

Container versions are managed in two places:

- Some versions in `group_vars/all.yaml` (referenced by templates)
- Newer services have versions directly in docker-compose.yaml files in `/configs/`
- Renovate is configured to automatically update container versions

### Available Services (in /configs/)

- **Monitoring**: monitoring-server, monitoring-client, uptimekuma, glowprom
- **Infrastructure**: traefik, authentik, op-connect, cloudflared, crowdsec
- **Applications**: calibre, audiobookshelf, mealie, stirlingpdf, atuin, freshrss, linkwarden, karakeep, littlelink, homepage
- **Other**: mosquitto, ntfy, portainer, postgresql, homebridge, scrypted, wallabag

### Adding a New Service

1. Run `task new-config -- <service-name>` to create from template
2. Edit `/configs/<service>/docker-compose.yaml` and `.env.st`
3. Add the service to the appropriate `host_vars/<hostname>.yaml` under `services_configs`
4. Deploy with `task run-machine -- <hostname>`
