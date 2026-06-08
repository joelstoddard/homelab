# proxmox_download_file is the non-deprecated alias for
# proxmox_virtual_environment_download_file (removed in bpg/proxmox v1.0).
resource "proxmox_download_file" "template" {
  content_type = "vztmpl"
  datastore_id = var.template_datastore_id
  node_name    = var.node_name
  url          = var.template_url
  file_name    = var.template_file_name
  overwrite    = false
  verify       = var.tls_verify
}

resource "proxmox_virtual_environment_container" "this" {
  node_name     = var.node_name
  vm_id         = var.vm_id
  description   = "Managed by OpenTofu."
  unprivileged  = var.unprivileged
  start_on_boot = var.start_on_boot

  operating_system {
    template_file_id = proxmox_download_file.template.id
    type             = "debian"
  }

  cpu {
    cores = var.cores
  }

  memory {
    dedicated = var.memory_mb
  }

  disk {
    datastore_id = var.disk_datastore_id
    size         = var.disk_size_gb
  }

  network_interface {
    name   = "eth0"
    bridge = var.network_bridge
  }

  initialization {
    hostname = var.hostname

    ip_config {
      ipv4 {
        address = var.static_ipv4_cidr != null ? var.static_ipv4_cidr : "dhcp"
        gateway = var.ipv4_gateway
      }
    }

    user_account {
      keys = var.ssh_public_keys
    }
  }

  features {
    nesting = var.nesting
    keyctl  = var.keyctl
  }
}
