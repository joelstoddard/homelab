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

variable "iso_url" {
  description = "Override the ISO source URL. Defaults to the vanilla siderolabs metal-amd64 release ISO for talos_version. Point at a Talos Image Factory URL to bake in extensions."
  type        = string
  default     = null
}

variable "iso_file_name" {
  description = "Datastore file name for the ISO."
  type        = string
  default     = null
}

locals {
  iso_url = coalesce(
    var.iso_url,
    "https://github.com/siderolabs/talos/releases/download/${var.talos_version}/metal-amd64.iso",
  )
  iso_file_name = coalesce(
    var.iso_file_name,
    "talos-${var.talos_version}-metal-amd64.iso",
  )
}
