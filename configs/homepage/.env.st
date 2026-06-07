FULL_DOMAIN={{ full_domain }}
TZ={{ default_timezone }}

# Proxmox
PVE_USER={{ proxmox_monitoring_user }}
PVE_PASSWORD={{ proxmox_monitoring_password }}

# Pi-hole
PIHOLE_PASSWORD={{ pihole_main_api_token }}
PIHOLE_BACKUP_PASSWORD={{ pihole_backup_api_token }}

# Monitoring
GRAFANA_USER={{ grafana_user }}
GRAFANA_PASSWORD={{ grafana_password }}

# Management
TRAEFIK_USER={{ traefik_user }}
TRAEFIK_PASSWORD={{ traefik_api_password }}
HOMEPAGE_ALLOWED_HOSTS=home.{{ full_domain }}
