variable "name" {
  description = "Container name. Must match a NetBox VM, e.g. 'bind9-01', 'lancache-02' or 'pihole-01'."
  type        = string

  validation {
    condition     = can(regex("^(bind9|lancache|pihole)-[0-9]{2}$", var.name))
    error_message = "name must look like 'bind9-NN', 'lancache-NN' or 'pihole-NN' (NN is two digits)."
  }
}

variable "node_name" {
  description = "Proxmox node the container lives on. Must match the device assignment in NetBox (a check asserts this)."
  type        = string
}

variable "template_file_id" {
  description = "Proxmox file ID of the Debian 13 template staged on this node, shared by every container on it."
  type        = string
}

variable "ipv4_gateway" {
  description = "LAN gateway IPv4."
  type        = string
}

variable "ssh_public_keys" {
  description = "SSH public keys for the root account, which Ansible connects as."
  type        = list(string)
}
