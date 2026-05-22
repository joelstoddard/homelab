# proxmox_download_file is the non-deprecated alias for
# proxmox_virtual_environment_download_file (removed in bpg/proxmox v1.0).
resource "proxmox_download_file" "image" {
  content_type       = "iso"
  datastore_id       = var.image_datastore_id
  node_name          = var.node_name
  url                = var.image_url
  file_name          = var.image_file_name
  overwrite          = false
  verify             = var.tls_verify
  checksum           = var.checksum
  checksum_algorithm = var.checksum == null ? null : var.checksum_algorithm
}

resource "proxmox_virtual_environment_vm" "template" {
  name        = var.template_name
  node_name   = var.node_name
  vm_id       = var.template_vm_id
  description = "Cloud-init template, managed by OpenTofu."
  template    = true

  agent {
    enabled = true
  }

  cpu {
    cores = var.cores
    type  = "host"
  }

  memory {
    dedicated = var.memory_mb
  }

  disk {
    datastore_id = var.disk_datastore_id
    file_id      = proxmox_download_file.image.id
    interface    = "scsi0"
    size         = var.disk_size_gb
    discard      = "on"
  }

  network_device {
    bridge = var.network_bridge
  }

  initialization {
    datastore_id = var.disk_datastore_id

    user_account {
      username = var.cloud_init_user
      keys     = var.cloud_init_ssh_keys
    }

    # Templates always use DHCP; cloud-init on cloned VMs configures the real network.
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }

  # Templates are permanently stopped so the QEMU agent can't report
  # these fields. Without this block, every plan shows them flipping
  # between [] and "known after apply" — refresh noise, not real change.
  # OpenTofu warns "ignore_changes has no effect" because these are
  # computed-only attributes; the warning is misleading — the
  # bpg/proxmox provider does honour the block in practice.
  lifecycle {
    ignore_changes = [
      ipv4_addresses,
      ipv6_addresses,
      network_interface_names,
    ]
  }
}
