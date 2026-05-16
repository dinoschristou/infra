locals {
  # Dictionary of VMs to provision
  vms = {
    "temp" = {
      target_node = "pve1"
      vmid        = 999 
      memory      = 4096
      cores       = 2
      cpu_type    = "x86-64-v2-AES"
      disk_size   = 40
      datastore   = "zdata"
      vlan        = 60
      ip          = "192.168.60.201/24"
      username    = "ubuntu"
    }
  }
}
