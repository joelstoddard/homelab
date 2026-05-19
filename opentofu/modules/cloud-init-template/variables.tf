variable "node_name" {
  description = "Proxmox node hostname to place the template on."
  type        = string
}

variable "template_name" {
  description = "Name of the resulting template VM in Proxmox."
  type        = string
}

variable "template_vm_id" {
  description = "VM ID of the template. Convention: 9000-9999 reserved for templates."
  type        = number

  validation {
    condition     = var.template_vm_id >= 9000 && var.template_vm_id <= 9999
    error_message = "template_vm_id must be in the 9000-9999 template range."
  }
}

variable "image_url" {
  description = "URL to the cloud image (qcow2 or raw)."
  type        = string
}

variable "image_file_name" {
  description = "Local filename Proxmox stores the image under. Required because the provider cannot reliably derive a filename from the URL (query strings, redirects). Must include the extension, e.g. 'debian-12-genericcloud-amd64.img'."
  type        = string
}

variable "image_datastore_id" {
  description = "Proxmox datastore for the downloaded image (typically 'local')."
  type        = string
  default     = "local"
}

variable "disk_datastore_id" {
  description = "Proxmox datastore for the template's disk (typically 'local-lvm')."
  type        = string
  default     = "local-lvm"
}

variable "cores" {
  description = "vCPU cores for the template."
  type        = number
  default     = 2

  validation {
    condition     = var.cores >= 1
    error_message = "cores must be at least 1."
  }
}

variable "memory_mb" {
  description = "Memory allocation in MB."
  type        = number
  default     = 2048

  validation {
    condition     = var.memory_mb >= 512
    error_message = "memory_mb must be at least 512 (Proxmox minimum)."
  }
}

variable "disk_size_gb" {
  description = "Root disk size in GB."
  type        = number
  default     = 20

  validation {
    condition     = var.disk_size_gb >= 1
    error_message = "disk_size_gb must be at least 1."
  }
}

variable "cloud_init_user" {
  description = "Default username injected via cloud-init."
  type        = string
}

variable "cloud_init_ssh_keys" {
  description = "SSH public keys authorized for cloud_init_user."
  type        = list(string)
}

variable "network_bridge" {
  description = "Linux bridge on the Proxmox node to attach the template NIC to."
  type        = string
  default     = "vmbr0"
}

variable "tls_verify" {
  description = "Verify the TLS certificate of the image URL. Disable only when the Proxmox node's TLS stack can't reach the upstream — at a minimum, supply a checksum when disabled."
  type        = bool
  default     = true
}

variable "checksum" {
  description = "Expected checksum of the downloaded image. Recommended when tls_verify is false. Null means no integrity check."
  type        = string
  default     = null
}

variable "checksum_algorithm" {
  description = "Algorithm used to compute var.checksum. Ignored if checksum is null."
  type        = string
  default     = "sha512"

  validation {
    condition     = contains(["md5", "sha1", "sha224", "sha256", "sha384", "sha512"], var.checksum_algorithm)
    error_message = "checksum_algorithm must be one of: md5, sha1, sha224, sha256, sha384, sha512."
  }
}
