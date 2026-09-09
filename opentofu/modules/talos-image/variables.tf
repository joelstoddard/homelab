variable "node_name" {
  description = "Proxmox node to stage the ISO on (NetBox device-name capitalization, e.g. 'Rumba')."
  type        = string
}

variable "datastore_id" {
  description = "Datastore that holds ISO images on this node."
  type        = string
  default     = "local"
}

# Passed in by each resources/<node>/talos.tf, which gets it from
# TF_VAR_talos_version (repo-root versions.env, injected by the Makefile).
# No default: the version has exactly one source of truth.
variable "talos_version" {
  description = "Talos release tag, e.g. 'v1.9.5'. Used to build the default ISO URL/name."
  type        = string

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", var.talos_version))
    error_message = "talos_version must look like 'vMAJOR.MINOR.PATCH'."
  }
}

# Image Factory schematic behind the ISO. Injected like talos_version
# (TF_VAR_talos_schematic_id from versions.env, by the Makefile), so the ISO
# is the build the talos role installs — see docs/design/talos-image-schematics.md.
variable "talos_schematic_id" {
  description = "Talos Image Factory schematic ID (64 hex chars) for the boot ISO. Injected from versions.env by the Makefile."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.talos_schematic_id))
    error_message = "talos_schematic_id must be a 64-character hex Image Factory schematic ID."
  }
}

variable "iso_url" {
  description = "Override the ISO source URL. Defaults to the Image Factory metal-amd64 ISO for (talos_schematic_id, talos_version)."
  type        = string
  default     = null
}

variable "iso_file_name" {
  description = "Datastore file name for the ISO."
  type        = string
  default     = null
}
