variable "ssh_public_key" {
  type        = string
  description = "The public SSH key to inject into the VMs via Cloud-Init"
  default     = "~/.ssh/id_ed25519.pub"
}

variable "dns_servers" {
  type        = list(string)
  description = "The DNS servers to configure in the VMs via Cloud-Init"
  default     = ["192.168.1.202", "192.168.3.254"]
}

variable "domain_name" {
  type        = string
  description = "The DNS domain name for the VMs"
  default     = "knxcloud.io"
}
