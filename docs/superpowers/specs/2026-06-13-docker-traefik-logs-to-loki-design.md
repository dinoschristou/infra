# Design: Ship Docker container + Traefik logs to Loki

**Date:** 2026-06-13
**Status:** Approved (design)
**Scope:** Phase 1 of log-collection expansion — Docker container logs on managed hosts.

## Problem

Promtail (the only log shipper, deployed via the `monitoring-client` role) currently
scrapes a single target — `/var/log/*log` — and mounts only `/var/log`. As a result,
Loki receives host syslog/varlogs but **no Docker container logs**.

Traefik is a special case: it is configured to write its application log and access log
to **files**, not stdout:

```yaml
# configs/traefik/traefik.yml.j2
log:
  filePath: "/var/log/traefik/traefik.log"   # -> <app_folder_root>/traefik/logs/traefik.log
accessLog:
  filePath: "/var/log/traefik/access.log"    # -> <app_folder_root>/traefik/logs/access.log (json)
```

So even after enabling Docker service discovery, Traefik's real logs would be missed —
they live on the host filesystem, not in Docker's json-file logs.

## Goal

Get all Docker container stdout/stderr logs **and** Traefik's file-based logs into Loki
across the 6 hosts running `monitoring-client` (`mon`, `infra`, `apps`, `mqtt`, `nvr`,
`external-01`), while keeping the existing `/var/log` scrape intact.

Out of scope (Phase 2): Proxmox hosts (`pve1`/`pve2`), Unifi controller, Home Assistant —
these run no agent and need a separate syslog/push ingestion path.

## Approach decisions

- **Docker logs:** Promtail `docker_sd_configs` (Docker socket service discovery). Dynamic
  discovery, rich labels, single shared config change. (Chosen over file-scraping
  `/var/lib/docker/containers` and over the Loki Docker driver plugin.)
- **Traefik:** Keep writing to files; add a dedicated promtail file scrape (option B). This
  preserves on-disk logs and the existing logrotate plan, at the cost of a second mechanism
  and a host-path mount.

## Changes

All changes are in `configs/monitoring-client/`. This is a single shared config that the
`services` role templates/copies to every host running `monitoring-client`, so the change
rolls out to all 6 hosts on the next `just run`.

### 1. `docker-compose.yaml` — promtail service mounts

Add two volume mounts to the `promtail` service:

```yaml
volumes:
  - /var/log:/var/log
  - ./promtail:/etc/promtail
  - /var/run/docker.sock:/var/run/docker.sock:ro   # docker service discovery
  - ${TRAEFIK_LOGS_DIR}:/var/log/traefik:ro          # Traefik on-disk logs
```

`docker-compose.yaml` is copied verbatim by the `services` role (not templated), so the
host-specific Traefik path is injected via an environment variable from `.env` (below)
rather than Jinja.

### 2. `.env.st` — host-correct Traefik log path

`.env.st` is Jinja-templated to `.env` by the role. Add:

```
TRAEFIK_LOGS_DIR={{ app_folder_root }}/traefik/logs
```

Resolves to `/opt/knxcloud/traefik/logs` on local VMs and `/opt/stacks/traefik/logs` on
`external-01` (via the `app_folder_root` override in `host_vars/external-01.yaml`).

### 3. `promtail/config.yaml.j2` — two new scrape jobs

Keep the existing `varlogs` job. Add:

**`docker` job** — `docker_sd_configs` against `unix:///var/run/docker.sock`. Relabel to a
small, low-cardinality label set:

- `host` = `{{ ansible_hostname }}`
- `container` = from `__meta_docker_container_name`
- `compose_service` = from `__meta_docker_container_label_com_docker_compose_service`
- `job` = `docker`

Drop Docker's other meta labels to avoid Loki cardinality blowup.

**`traefik` job** — `static_configs` scraping `/var/log/traefik/*.log`:

- `host` = `{{ ansible_hostname }}`
- `job` = `traefik`
- Promtail auto-adds a `filename` label, distinguishing `traefik.log` from `access.log`.
- A pipeline stage parses the JSON `access.log` for the timestamp. Lines are shipped raw —
  **no** per-request labels (path/status/IP) to keep cardinality sane; those stay queryable
  as log content/fields.

## Result in Grafana

- `{job="docker"}` — every container's stdout/stderr across all hosts; filter by
  `container="traefik"`, `compose_service="grafana"`, etc.
- `{job="traefik"}` — Traefik app log + JSON access log; filter by `filename`.
- `{job="varlogs"}` — unchanged.

## Notes

- **Disk usage:** Traefik continues logging to files (option B), so Docker's log growth is
  unchanged and Traefik rotation remains as-is (the commented logrotate example in
  `traefik.yml.j2`). Not modified here.
- **Cardinality discipline:** deliberately not labeling by request path/status/IP.
- **Socket access:** promtail gets read-only access to the Docker socket for discovery.

## Verification

After `just run` (or `just run-machine <host>`):

1. `docker logs promtail` on a target host shows no scrape errors.
2. In Grafana Explore (Loki): `{job="docker"}` returns container logs; `{container="traefik"}`
   and `{job="traefik"}` both return data.
3. `{job="varlogs"}` still returns host logs (regression check).
