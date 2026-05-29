# Stages the Talos ISO on this node and hands its file ID to the k8s VMs
# (see main.tf) so they boot into Talos maintenance mode. The talos
# Ansible role then applies machine configs over the API.
#
# Keep talos_version in sync with ansible/roles/talos/defaults (talosctl /
# installer) and ansible/roles/00-pxe/defaults (Pi netboot assets).
variable "talos_version" {
  description = "Talos release tag for the boot ISO, e.g. 'v1.9.5'."
  type        = string
  default     = "v1.9.5"
}

module "talos_image" {
  source        = "../../modules/talos-image"
  node_name     = "Rumba"
  datastore_id  = "local"
  talos_version = var.talos_version
}

output "talos_iso_file_id" {
  value = module.talos_image.file_id
}
