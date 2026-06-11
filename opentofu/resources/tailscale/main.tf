module "lxc" {
  source = "../../modules/lxc"

  node_name          = var.tailscale_node
  vm_id              = var.tailscale_vm_id
  hostname           = var.tailscale_hostname
  template_url       = var.tailscale_template_url
  template_file_name = var.tailscale_template_file_name
  ssh_public_keys    = [trimspace(file(pathexpand(var.operator_ssh_public_key_path)))]

  template_datastore_id = "local"
  disk_datastore_id     = "local"
  cores                 = 1
  memory_mb             = 512
  disk_size_gb          = 4

  # DHCP — the subnet router only needs outbound connectivity.
  # No static IP required; provisioning goes through the hypervisor via pct.

  # Only nesting here — keyctl requires root@pam (not an API token).
  # The tun_passthrough provisioner sets both via pct set over SSH.
  nesting = true
}

# /dev/net/tun passthrough for kernel-level packet forwarding.
# Uses the PVE 8.1+ device-passthrough feature (pct set --dev0).
resource "null_resource" "tun_passthrough" {
  triggers = {
    container_mac = module.lxc.primary_mac_address
  }

  connection {
    type        = "ssh"
    host        = local.node_ssh_host
    user        = "root"
    private_key = file(pathexpand(var.operator_ssh_private_key_path))
    timeout     = "2m"
    host_key    = ""
  }

  provisioner "remote-exec" {
    inline = [
      "pct stop ${module.lxc.vm_id} || true",
      "pct set ${module.lxc.vm_id} --dev0 /dev/net/tun",
      "pct start ${module.lxc.vm_id}",
      "sleep 10",
    ]
  }

  depends_on = [module.lxc]
}

resource "null_resource" "tailscale_install" {
  triggers = {
    script_sha    = sha256(local.tailscale_install_script)
    container_mac = module.lxc.primary_mac_address
  }

  connection {
    type        = "ssh"
    host        = local.node_ssh_host
    user        = "root"
    private_key = file(pathexpand(var.operator_ssh_private_key_path))
    timeout     = "2m"
    host_key    = ""
  }

  provisioner "file" {
    content     = local.tailscale_install_script
    destination = "/tmp/tailscale-bootstrap.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "pct push ${module.lxc.vm_id} /tmp/tailscale-bootstrap.sh /root/tailscale-bootstrap.sh",
      "pct exec ${module.lxc.vm_id} -- bash /root/tailscale-bootstrap.sh",
      "pct exec ${module.lxc.vm_id} -- rm -f /root/tailscale-bootstrap.sh",
      "rm -f /tmp/tailscale-bootstrap.sh",
      "pct exec ${module.lxc.vm_id} -- tailscale up --auth-key='${var.tailscale_auth_key}' --advertise-routes='${var.tailscale_advertised_cidr}' --advertise-exit-node --hostname='${var.tailscale_hostname}' --accept-dns=false",
      "pct exec ${module.lxc.vm_id} -- tailscale status",
    ]
  }

  depends_on = [null_resource.tun_passthrough]
}
