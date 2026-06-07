variable "domain" {
  type    = string
  default = "lab.internal"
}

variable "unifi_network_id" {
  type        = string
  description = "Network ID in Unifi to bind fixed IPs"
}

variable "pve_image" {
  type        = string
  description = "File ID of the Proxmox image to use"
  default     = "local:iso/ubuntu-22.04-server-cloudimg-amd64.img"
}

variable "ssh_keys" {
  type    = list(string)
  default = []
}

locals {
  vms = {
    mon = {
      pve_node   = "pve1"
      ip_address = "192.168.60.44"
      mac_address = "00:00:00:00:00:01" # Placeholders
      vlan_id    = 60
    }
    infra = {
      pve_node   = "pve1"
      ip_address = "192.168.60.45"
      mac_address = "00:00:00:00:00:02" # Placeholders
      vlan_id    = 60
    }
    mqtt = {
      pve_node   = "pve2"
      ip_address = "192.168.42.122"
      mac_address = "00:00:00:00:00:03" # Placeholders
      vlan_id    = 42
    }
    apps = {
      pve_node   = "pve2"
      ip_address = "192.168.60.46"
      mac_address = "00:00:00:00:00:04" # Placeholders
      vlan_id    = 60
    }
  }
}

module "vm" {
  source   = "./modules/vm"
  for_each = local.vms

  vm_name          = each.key
  pve_node         = each.value.pve_node
  ip_address       = each.value.ip_address
  mac_address      = each.value.mac_address
  vlan_id          = each.value.vlan_id
  unifi_network_id = var.unifi_network_id
  domain           = var.domain
  image_file_id    = var.pve_image
  ssh_keys         = var.ssh_keys
}
