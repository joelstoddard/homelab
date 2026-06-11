variable "proxmox_endpoint" {
  description = "Proxmox VE API endpoint. Injected via TF_VAR_proxmox_endpoint from opentofu/secrets.sops.yaml."
  type        = string
}

variable "proxmox_api_token" {
  description = "Proxmox API token. Injected via TF_VAR_proxmox_api_token from ansible/inventory/group_vars/proxmox.sops.yaml."
  type        = string
  sensitive   = true
}

variable "proxmox_insecure" {
  description = "Skip TLS verification on the Proxmox endpoint."
  type        = bool
  default     = true
}

variable "netbox_url" {
  description = "NetBox base URL. Injected via TF_VAR_netbox_url from NETBOX_URL."
  type        = string
}

variable "netbox_token" {
  description = "NetBox API token. Injected via TF_VAR_netbox_token from NETBOX_TOKEN."
  type        = string
  sensitive   = true
}

variable "operator_ssh_private_key_path" {
  description = "Path to the operator's SSH private key. Used to SSH into the Proxmox node for pct commands."
  type        = string
  default     = "~/.ssh/id_rsa"
}

variable "operator_ssh_public_key_path" {
  description = "Path to the operator's SSH public key. Injected into the LXC's root authorized_keys."
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "proxmox_ssh_host" {
  description = "Override for the Proxmox node SSH host. Defaults to the primary IPv4 of tailscale_node looked up from NetBox."
  type        = string
  default     = null
}

variable "tailscale_node" {
  description = "Proxmox node hosting the Tailscale subnet-router LXC."
  type        = string
  default     = "Tango"
}

variable "tailscale_vm_id" {
  description = "Proxmox VM ID for the Tailscale container."
  type        = number
  default     = 300
}

variable "tailscale_hostname" {
  description = "LXC hostname (also used as the Tailscale machine name)."
  type        = string
  default     = "homelab"
}

variable "tailscale_auth_key" {
  description = "Tailscale auth key for joining the tailnet. Generate a reusable key in the Tailscale admin console. Injected via TF_VAR_tailscale_auth_key from secrets.env."
  type        = string
  sensitive   = true
}

variable "tailscale_advertised_cidr" {
  description = "Subnet CIDR to advertise via Tailscale. Must exist as a prefix in NetBox IPAM."
  type        = string
  default     = "192.168.1.0/24"
}

variable "tailscale_template_url" {
  description = "URL of the Debian 12 LXC template."
  type        = string
  default     = "http://download.proxmox.com/images/system/debian-12-standard_12.12-1_amd64.tar.zst"
}

variable "tailscale_template_file_name" {
  description = "On-disk filename for the LXC template."
  type        = string
  default     = "debian-12-standard_12.12-1_amd64.tar.zst"
}
