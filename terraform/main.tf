# Download the Ubuntu 26.04 LTS (Resolute Raccoon) Cloud Image
# We download this to the 'local' datastore on pve1.
# By default, Proxmox's 'local' datastore supports 'iso' content types.
resource "proxmox_virtual_environment_download_file" "ubuntu_cloud_image" {
  content_type = "iso"
  datastore_id = "local"
  node_name    = "pve1"
  url          = "https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64.img"
  file_name    = "ubuntu-26.04-resolute-cloudimg-amd64.img"
}

resource "proxmox_virtual_environment_file" "vendor_data" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = "pve1"

  source_raw {
    data = <<EOF
#cloud-config
packages:
  - qemu-guest-agent
runcmd:
  - systemctl enable qemu-guest-agent
  - systemctl start qemu-guest-agent
EOF
    file_name = "vendor-data.yaml"
  }
}

resource "proxmox_virtual_environment_vm" "vms" {
  for_each = local.vms

  name        = each.key
  description = "Managed by Terraform"
  tags        = ["terraform", "ubuntu"]
  node_name   = each.value.target_node
  vm_id       = each.value.vmid

  # Stop the VM gracefully when destroying or updating
  stop_on_destroy = true

  agent {
    # Ensure qemu-guest-agent is enabled
    enabled = true
  }

  cpu {
    cores = each.value.cores
    type  = each.value.cpu_type
  }

  memory {
    dedicated = each.value.memory
  }

  disk {
    datastore_id = each.value.datastore
    file_id      = proxmox_virtual_environment_download_file.ubuntu_cloud_image.id
    interface    = "scsi0"
    discard      = "on"
    size         = each.value.disk_size
  }

  network_device {
    bridge  = "vmbr1"
    # vlan_id = each.value.vlan
  }

  initialization {
    datastore_id = each.value.datastore
    vendor_data_file_id = proxmox_virtual_environment_file.vendor_data.id
    
    ip_config {
      ipv4 {
        address = each.value.ip
        gateway = "192.168.${each.value.vlan}.1"
      }
    }

    dns {
      domain  = var.domain_name
      servers = var.dns_servers
    }

    user_account {
      username = each.value.username
      keys     = [file(var.ssh_public_key)]
    }
  }

  # Ensure the cloud image is downloaded before creating VMs
  depends_on = [
    proxmox_virtual_environment_download_file.ubuntu_cloud_image
  ]
}
