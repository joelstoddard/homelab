variable "proxmox_endpoint" {
  description = "Proxmox VE API endpoint, e.g. https://<leader-fqdn>:8006/. Injected via TF_VAR_proxmox_endpoint from opentofu/secrets.sops.yaml."
  type        = string
}

variable "proxmox_api_token" {
  description = "Proxmox API token (root@pam!terraform=<secret>). Injected via TF_VAR_proxmox_api_token from ansible/inventory/group_vars/proxmox.sops.yaml."
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

variable "lan_gateway" {
  description = "LAN gateway IPv4. Shared across resources; injected via TF_VAR_lan_gateway from opentofu/secrets.sops.yaml."
  type        = string
}

variable "operator_ssh_public_key_path" {
  description = "Path to the operator's SSH public key, injected into each container's root authorized_keys for Ansible."
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "template_url" {
  description = "URL of the Debian 13 LXC template. Every link needs trixie: see ansible/roles/dns/README.md."
  type        = string
  default     = "http://download.proxmox.com/images/system/debian-13-standard_13.6-1_amd64.tar.zst"
}

variable "template_file_name" {
  description = "On-disk filename for the LXC template."
  type        = string
  default     = "debian-13-standard_13.6-1_amd64.tar.zst"
}

variable "template_checksum" {
  description = "SHA-512 of the template, from Proxmox's GPG-signed aplinfo index. download.proxmox.com has no valid HTTPS, so this is the only integrity check."
  type        = string
  default     = "4c0c27ca6ceab5ef0b84db57825a00f26157ef1854bafe97297813e1cbe8ecb8cc9c453cab6b3b0efe1ba193a50c47ece1e41d950e411b8730b835b71e9e754b"
}
