FULL_DOMAIN={{ full_domain }}

# Proxmox
PVE_USER={{ vault_pve_user }}
PVE_PASSWORD={{ vault_pve_password }}

# Pi-hole
PIHOLE_PASSWORD={{ vault_pihole_password }}
PIHOLE_BACKUP_PASSWORD={{ vault_pihole_backup_password }}

# Monitoring
GRAFANA_USER={{ grafana_user }}
GRAFANA_PASSWORD={{ vault_grafana_password }}
UPTIME_KUMA_SLUG={{ uptime_kuma_slug | default('default') }}

# Management
PORTAINER_API_KEY={{ vault_portainer_api_key }}
TRAEFIK_USER={{ vault_traefik_user }}
TRAEFIK_PASSWORD={{ vault_traefik_password }}

# Applications
MEALIE_API_KEY={{ vault_mealie_api_key }}
AUDIOBOOKSHELF_API_KEY={{ vault_audiobookshelf_api_key }}

# External
FRESHRSS_USER={{ vault_freshrss_user }}
FRESHRSS_PASSWORD={{ vault_freshrss_password }}
LINKWARDEN_API_KEY={{ vault_linkwarden_api_key }}
