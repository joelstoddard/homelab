locals {
  # Installers come only from the Image Factory since Talos 1.14, so the
  # ISO is the same schematic the talos role installs (extensions and all).
  # The file name carries version AND schematic: proxmox_download_file is
  # replaced on url/file_name, and create_before_destroy needs the new name
  # to differ from the one still mounted.
  iso_url = coalesce(
    var.iso_url,
    "https://factory.talos.dev/image/${var.talos_schematic_id}/${var.talos_version}/metal-amd64.iso",
  )
  iso_file_name = coalesce(
    var.iso_file_name,
    "talos-${var.talos_version}-${substr(var.talos_schematic_id, 0, 8)}-metal-amd64.iso",
  )
}
