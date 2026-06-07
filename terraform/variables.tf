variable "proxmox_api_url" {
  type        = string
  description = "Proxmox API URL"
}

variable "proxmox_api_token_id" {
  type        = string
  description = "Proxmox API Token ID"
  sensitive   = true
}

variable "unifi_username" {
  type        = string
  description = "Unifi Username"
}

variable "unifi_password" {
  type        = string
  description = "Unifi Password"
  sensitive   = true
}

variable "unifi_api_url" {
  type        = string
  description = "Unifi API URL"
}

variable "pihole_url" {
  type        = string
  description = "Pi-hole URL"
}

variable "pihole_password" {
  type        = string
  description = "Pi-hole Password"
  sensitive   = true
}
