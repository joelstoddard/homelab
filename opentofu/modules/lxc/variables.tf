variable "node_name" {
  description = "Proxmox node to host the container, e.g. \"Rumba\"."
  type        = string
}

variable "vm_id" {
  description = "Proxmox VM ID. Choose outside the template-id range (9000+)."
  type        = number
}

variable "hostname" {
  description = "Container hostname."
  type        = string
}

variable "template_url" {
  description = "URL of a Proxmox LXC .tar.zst template."
  type        = string
}

variable "template_file_name" {
  description = "On-disk filename for the downloaded template."
  type        = string
}

variable "template_datastore_id" {
  description = "Datastore that holds container templates (typically \"local\")."
  type        = string
  default     = "local"
}

variable "disk_datastore_id" {
  description = "Datastore for the container rootfs."
  type        = string
  default     = "local"
}

variable "disk_size_gb" {
  description = "Container rootfs size in GiB."
  type        = number
  default     = 8

  validation {
    condition     = var.disk_size_gb >= 1
    error_message = "disk_size_gb must be at least 1."
  }
}

variable "cores" {
  description = "CPU cores assigned to the container."
  type        = number
  default     = 2

  validation {
    condition     = var.cores >= 1
    error_message = "cores must be at least 1."
  }
}

variable "memory_mb" {
  description = "RAM assigned to the container, in MiB."
  type        = number
  default     = 1024

  validation {
    condition     = var.memory_mb >= 256
    error_message = "memory_mb must be at least 256 (LXC minimum)."
  }
}

variable "network_bridge" {
  description = "Proxmox network bridge."
  type        = string
  default     = "vmbr0"
}

variable "static_ipv4_cidr" {
  description = "Static IPv4 in CIDR form, e.g. \"192.168.1.2/24\". Null for DHCP."
  type        = string
  default     = null
}

variable "ipv4_gateway" {
  description = "IPv4 default gateway. Required when static_ipv4_cidr is set."
  type        = string
  default     = null
}

variable "ssh_public_keys" {
  description = "SSH public keys to inject for the root account."
  type        = list(string)
}

variable "unprivileged" {
  description = "Run as an unprivileged LXC."
  type        = bool
  default     = true
}

variable "start_on_boot" {
  description = "Auto-start the container on Proxmox boot."
  type        = bool
  default     = true
}

variable "nesting" {
  description = "Enable LXC nesting feature (required for systemd, Tailscale, etc.)."
  type        = bool
  default     = false
}

variable "keyctl" {
  description = "Enable LXC keyctl feature."
  type        = bool
  default     = false
}

variable "tls_verify" {
  description = "Verify TLS when downloading the LXC template."
  type        = bool
  default     = true
}
