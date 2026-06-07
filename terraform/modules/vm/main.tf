terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.68.0"
    }
    unifi = {
      source  = "paultyng/unifi"
      version = ">= 0.41.0"
    }
    pihole = {
      source  = "ryanwholey/pihole"
      version = ">= 0.2.0"
    }
  }
}

resource "proxmox_virtual_environment_vm" "vm" {
  node_name = var.pve_node
  name      = var.vm_name

  cpu {
    cores = var.cores
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = var.memory
  }

  disk {
    datastore_id = var.datastore_id
    file_id      = var.image_file_id
    interface    = "scsi0"
    size         = var.disk_size
  }

  network_device {
    bridge      = "vmbr0"
    mac_address = var.mac_address
    vlan_id     = var.vlan_id
  }

  initialization {
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
    user_account {
      username = "ubuntu"
      keys     = var.ssh_keys
    }
  }
}

resource "unifi_user" "client" {
  mac  = var.mac_address
  name = var.vm_name
  fixed_ip   = var.ip_address
  network_id = var.unifi_network_id
}

resource "pihole_dns_record" "record" {
  domain = "${var.vm_name}.${var.domain}"
  ip     = var.ip_address
}
