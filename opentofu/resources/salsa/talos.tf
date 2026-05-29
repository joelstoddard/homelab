# Stages the Talos ISO on this node and hands its file ID to the k8s VMs
# (see main.tf) so they boot into Talos maintenance mode. The talos
# Ansible role then applies machine configs over the API.
#
# talos_version is injected by opentofu/Makefile (TF_VAR_talos_version)
# from repo-root versions.env — the single source of truth. No default, so
# `tofu` run outside `make` will (correctly) prompt for it.
variable "talos_version" {
  description = "Talos release tag for the boot ISO, e.g. 'v1.9.5'. Injected from versions.env by the Makefile."
  type        = string
}

module "talos_image" {
  source        = "../../modules/talos-image"
  node_name     = "Salsa"
  datastore_id  = "local"
  talos_version = var.talos_version
}

output "talos_iso_file_id" {
  value = module.talos_image.file_id
}
