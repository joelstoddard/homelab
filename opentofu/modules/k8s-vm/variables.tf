variable "vm_name" {
  description = "k8s VM name. Must match a NetBox VM, e.g. 'k8s-server-01' or 'k8s-agent-03'."
  type        = string

  validation {
    condition     = can(regex("^k8s-(server|agent)-[0-9]{2}$", var.vm_name))
    error_message = "vm_name must look like 'k8s-server-NN' or 'k8s-agent-NN' (NN is two digits)."
  }
}

variable "node_name" {
  description = "Proxmox node the VM lives on. Must match the device assignment in NetBox (a precondition asserts this)."
  type        = string
}

variable "disk_datastore_id" {
  description = "Proxmox datastore for the VM disk + EFI nvram."
  type        = string
  default     = "local"
}

variable "network_bridge" {
  description = "Linux bridge to attach net0 to."
  type        = string
  default     = "vmbr0"
}
