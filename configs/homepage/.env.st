FULL_DOMAIN={{ full_domain }}

# Proxmox
PVE_USER={{ proxmox_monitoring_user }}
PVE_PASSWORD={{ proxmox_monitoring_password }}

# Pi-hole
PIHOLE_PASSWORD={{ pihole_main_api_token }}
PIHOLE_BACKUP_PASSWORD={{ pihole_backup_api_token }}

# Monitoring
GRAFANA_USER={{ grafana_user }}
GRAFANA_PASSWORD={{ grafana_password }}
UPTIME_KUMA_SLUG={{ uptime_kuma_slug | default('default') }}

# Management
PORTAINER_API_KEY={{ vault_portainer_api_key }}
TRAEFIK_USER={{ traefik_user }}
TRAEFIK_PASSWORD={{ traefik_password }}

# Applications
MEALIE_API_KEY={{ vault_mealie_api_key }}
AUDIOBOOKSHELF_API_KEY={{ vault_audiobookshelf_api_key }}

# External
FRESHRSS_USER={{ vault_freshrss_user }}
FRESHRSS_PASSWORD={{ vault_freshrss_password }}
LINKWARDEN_API_KEY={{ vault_linkwarden_api_key }}
HOMEPAGE_ALLOWED_HOSTS=*
