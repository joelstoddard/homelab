variable "node_name" {
  description = "Proxmox node to place the VM on (matches NetBox device name capitalization, e.g. 'Rumba')."
  type        = string
}

variable "vm_name" {
  description = "Proxmox VM name."
  type        = string
}

variable "vm_id" {
  description = "Proxmox VM ID. By repo convention 9000-9999 is reserved for templates; runtime VMs use 100-8999."
  type        = number

  validation {
    condition     = var.vm_id >= 100 && var.vm_id <= 8999
    error_message = "vm_id must be in the 100-8999 VM range (9000+ reserved for templates)."
  }
}

variable "cores" {
  description = "vCPU cores."
  type        = number

  validation {
    condition     = var.cores >= 1
    error_message = "cores must be at least 1."
  }
}

variable "memory_mb" {
  description = "Memory in MB."
  type        = number

  validation {
    condition     = var.memory_mb >= 512
    error_message = "memory_mb must be at least 512 (Proxmox minimum)."
  }
}

variable "disk_size_gb" {
  description = "Root disk size in GB. Created empty."
  type        = number

  validation {
    condition     = var.disk_size_gb >= 1
    error_message = "disk_size_gb must be at least 1."
  }
}

variable "disk_datastore_id" {
  description = "Proxmox datastore for the VM disk and EFI nvram."
  type        = string
  default     = "local"
}

variable "network_bridge" {
  description = "Linux bridge on the Proxmox node."
  type        = string
  default     = "vmbr0"
}

variable "mac_address" {
  description = "MAC address for net0."
  type        = string

  validation {
    condition     = can(regex("^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$", var.mac_address))
    error_message = "mac_address must be a colon-separated 6-byte hex MAC."
  }
}

variable "tags" {
  description = "Proxmox tags (alphabetical, lower-case)."
  type        = list(string)
  default     = []
}

variable "description" {
  description = "Human-readable VM description."
  type        = string
  default     = "Empty-shell Proxmox VM, managed by OpenTofu. Installer media attaches separately."
}
