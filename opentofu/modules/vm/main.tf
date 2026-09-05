resource "proxmox_virtual_environment_vm" "vm" {
  name        = var.vm_name
  node_name   = var.node_name
  vm_id       = var.vm_id
  description = var.description
  tags        = var.tags

  # Empty shell until an installer ISO is attached. Once var.iso_file_id
  # is set the VM is started and boots disk-first, falling through to the
  # ISO only while the disk is blank — so the very first boot lands in
  # Talos maintenance mode, and every boot after the install reads the
  # installed system off disk without needing the ISO detached.
  started = var.iso_file_id != null
  on_boot = var.iso_file_id != null

  boot_order = var.iso_file_id != null ? ["scsi0", "ide2"] : null

  # Talos requires UEFI.
  bios = "ovmf"

  # Talos does not ship QEMU guest agent.
  agent {
    enabled = false
  }

  operating_system {
    type = "l26"
  }

  cpu {
    cores = var.cores
    type  = "host"
  }

  memory {
    dedicated = var.memory_mb
  }

  efi_disk {
    datastore_id = var.disk_datastore_id
    type         = "4m"
  }

  # Empty disk; Talos installs onto it.
  disk {
    datastore_id = var.disk_datastore_id
    interface    = "scsi0"
    size         = var.disk_size_gb
    discard      = "on"
  }

  # CD-ROM slot for installer media. Holds the Talos ISO once
  # var.iso_file_id is set; an empty shell leaves it as "none".
  cdrom {
    interface = "ide2"
    file_id   = var.iso_file_id != null ? var.iso_file_id : "none"
  }

  network_device {
    bridge      = var.network_bridge
    mac_address = upper(var.mac_address)
  }
}
