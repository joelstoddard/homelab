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
