output "file_id" {
  description = "Proxmox file ID of the staged ISO (datastore:iso/filename), for a VM's cdrom file_id."
  value       = proxmox_download_file.talos_iso.id
}
