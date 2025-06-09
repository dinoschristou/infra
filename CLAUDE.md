# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

All operations use `task` command (Go Task):

### Core Deployment
- `task run` - Deploy all services except DNS to all hosts
- `task run-machine -- <hostname>` - Deploy to specific machine (e.g., thorondor, varda)
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
- `task nut-server` - Configure UPS server on pve3
- `task nut-client` - Configure UPS clients on pve1, pve2

### Testing
- `task test-new-roles` - Test roles on designated test hosts

## Architecture

### Infrastructure Layout
This manages a home lab with 4 Proxmox VMs (thorondor, varda, gondor, earendil), 3 Proxmox hosts (pve1-3), dual Pi-hole DNS servers, and external cloud servers. All services deploy to `/opt/knxcloud/` using the knxcloud.io domain.

### Service Management
Services are controlled via the services dictionary in the group or host vars i.e. `services_configs`. Each service has Docker Compose config and a `.env.st` in `/configs/<service>/`. The `.env.st` file is a jinja template where vars get substituted in. Services get deployed using the `services` role.

The older docker_services role is deprecated. As are the enable_service flags.
### Key Infrastructure Components
- **Monitoring Stack**: Prometheus, Grafana, Loki, Alertmanager in monitoring-server
- **Reverse Proxy**: Traefik with Cloudflare ACME SSL
- **Identity**: Authentik for SSO
- **DNS**: Dual Pi-hole instances for redundancy
- **Power**: Network UPS Tools (NUT) for graceful shutdowns

### Variable Structure
- `group_vars/all.yaml` - Global settings, feature flags, container versions
- `host_vars/<hostname>.yaml` - Host-specific overrides and service assignments
- `vars/vault.yaml` - Encrypted secrets (always keep encrypted in commits)

### Container Version Management
All container versions were centrally managed in group_vars/all.yaml. But in the new model, they are held in place in the docker compose files in `/configs`.