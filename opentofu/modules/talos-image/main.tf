# Downloads the Talos metal ISO onto one Proxmox node's datastore so the
# node's k8s VMs can boot it from their CD-ROM into maintenance mode. The
# talos role (../../ansible/roles/talos) then pushes machine configs over
# the API and the VMs install to disk.
#
# One instance per node: directory-backed datastores (`local`) are
# per-node, so each NUC needs its own copy of the ISO. Mirrors the
# download pattern in modules/cloud-init-template.
resource "proxmox_download_file" "talos_iso" {
  content_type = "iso"
  datastore_id = var.datastore_id
  node_name    = var.node_name
  url          = local.iso_url
  file_name    = local.iso_file_name
  overwrite    = false
}
