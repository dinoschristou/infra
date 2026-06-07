variable "pve_node" {
  type        = string
  description = "Proxmox node name"
}

variable "vm_name" {
  type        = string
  description = "Name of the virtual machine"
}

variable "cores" {
  type        = number
  description = "Number of CPU cores"
  default     = 2
}

variable "memory" {
  type        = number
  description = "Amount of memory in MB"
  default     = 2048
}

variable "datastore_id" {
  type        = string
  description = "Proxmox datastore ID"
  default     = "local-lvm"
}

variable "image_file_id" {
  type        = string
  description = "Proxmox file ID for the OS image"
}

variable "disk_size" {
  type        = number
  description = "Size of the root disk in GB"
  default     = 20
}

variable "mac_address" {
  type        = string
  description = "MAC address of the network device"
}

variable "vlan_id" {
  type        = number
  description = "VLAN ID for the network interface"
  default     = 0
}

variable "ssh_keys" {
  type        = list(string)
  description = "SSH public keys to inject"
  default     = []
}

variable "ip_address" {
  type        = string
  description = "Reserved IP address"
}

variable "unifi_network_id" {
  type        = string
  description = "Unifi Network ID to assign the fixed IP to"
}

variable "domain" {
  type        = string
  description = "Domain for the Pi-hole DNS record"
}
