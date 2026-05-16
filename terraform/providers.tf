terraform {
  required_version = ">= 1.5.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.70.1"
    }
  }
}

provider "proxmox" {
  # Endpoint and credentials will be read from environment variables:
  # PROXMOX_VE_ENDPOINT
  # PROXMOX_VE_USERNAME / PROXMOX_VE_API_TOKEN
  # PROXMOX_VE_PASSWORD / PROXMOX_VE_API_TOKEN

  # Allow self-signed certificates since it's a homelab
  insecure = true

  # Configuration for SSH connections to Proxmox nodes (required for disk imports)
  ssh {
    agent       = false
    username    = "root"
    private_key = file("~/.ssh/id_ed25519") # Adjust if your key is id_rsa
  }
}
