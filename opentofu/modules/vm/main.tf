resource "proxmox_virtual_environment_vm" "vm" {
  name        = var.vm_name
  node_name   = var.node_name
  vm_id       = var.vm_id
  description = var.description
  tags        = var.tags

  # Hands off to the Talos thread for boot + start.
  started = false
  on_boot = false

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

  # Empty CD-ROM slot. Talos thread attaches installer media here.
  cdrom {
    interface = "ide2"
    file_id   = "none"
  }

  network_device {
    bridge      = var.network_bridge
    mac_address = upper(var.mac_address)
  }
}
