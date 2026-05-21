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

variable "operator_ssh_private_key_path" {
  description = "Path to the operator's SSH private key. Used to drive the LXC's remote-exec installer + gravity-apply. Override for non-RSA keypairs (e.g. \"~/.ssh/id_ed25519\")."
  type        = string
  default     = "~/.ssh/id_rsa"
}

variable "operator_ssh_public_key_path" {
  description = "Path to the operator's SSH public key. Injected into the LXC's root authorized_keys via the container's initialization block."
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "pihole_node" {
  description = "Proxmox node hosting the Pi-hole LXC."
  type        = string
  default     = "Rumba"
}

variable "pihole_vm_id" {
  description = "Proxmox VM ID for the Pi-hole container."
  type        = number
  default     = 200
}

variable "pihole_hostname" {
  description = "LXC hostname."
  type        = string
  default     = "pihole"
}

variable "pihole_static_ipv4_cidr" {
  description = "Pi-hole static IPv4 in CIDR form. Resource-scoped; injected via TF_VAR_pihole_static_ipv4_cidr from opentofu/resources/pihole/secrets.sops.yaml."
  type        = string
}

variable "lan_gateway" {
  description = "LAN gateway IPv4. Shared across resources; injected via TF_VAR_lan_gateway from opentofu/secrets.sops.yaml."
  type        = string
}

variable "pihole_web_password" {
  description = "Pi-hole admin/API password. Resource-scoped; injected via TF_VAR_pihole_web_password from opentofu/resources/pihole/secrets.sops.yaml."
  type        = string
  sensitive   = true
}

variable "pihole_upstream_dns" {
  description = "Upstream resolvers for Pi-hole to forward to. Must have at least one entry; the second (if present) becomes PIHOLE_DNS_2."
  type        = list(string)
  default     = ["9.9.9.9", "1.1.1.1"]

  validation {
    condition     = length(var.pihole_upstream_dns) >= 1
    error_message = "pihole_upstream_dns must contain at least one resolver."
  }
}

variable "pihole_template_url" {
  description = "URL of the Debian 12 LXC template."
  type        = string
  default     = "http://download.proxmox.com/images/system/debian-12-standard_12.12-1_amd64.tar.zst"
}

variable "pihole_template_file_name" {
  description = "On-disk filename for the LXC template."
  type        = string
  default     = "debian-12-standard_12.12-1_amd64.tar.zst"
}

variable "pihole_adlists" {
  description = "Adlist URLs to seed into Pi-hole's Default group. Defaults to the set extracted from teleporter backup 2026-05-10."
  type        = list(string)

  validation {
    condition     = length(var.pihole_adlists) == length(toset(var.pihole_adlists))
    error_message = "pihole_adlists contains duplicate URLs. for_each toset() would silently dedupe; surfacing it here so a copy-paste typo doesn't quietly collapse two intended entries into one."
  }

  default = []
}
