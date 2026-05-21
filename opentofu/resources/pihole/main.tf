locals {
  pihole_host_ipv4 = split("/", var.pihole_static_ipv4_cidr)[0]

  pihole_install_script = templatefile("${path.module}/templates/install.sh.tftpl", {
    static_ipv4_cidr = var.pihole_static_ipv4_cidr
    dns_1            = var.pihole_upstream_dns[0]
    dns_2            = length(var.pihole_upstream_dns) > 1 ? var.pihole_upstream_dns[1] : ""
    web_password     = var.pihole_web_password
  })
}

module "lxc" {
  source = "../../modules/lxc"

  node_name          = var.pihole_node
  vm_id              = var.pihole_vm_id
  hostname           = var.pihole_hostname
  template_url       = var.pihole_template_url
  template_file_name = var.pihole_template_file_name
  static_ipv4_cidr   = var.pihole_static_ipv4_cidr
  ipv4_gateway       = var.lan_gateway
  ssh_public_keys    = [trimspace(file(pathexpand(var.operator_ssh_public_key_path)))]

  # rumba's only datastore is `local`; matches the rumba template module.
  template_datastore_id = "local"
  disk_datastore_id     = "local"
}

resource "null_resource" "pihole_install" {
  # `container_mac` (the eth0 MAC Proxmox auto-assigns at creation)
  # rather than `vm_id` (a constant input) so the installer re-runs
  # when the LXC itself is replaced. Without that, Proxmox-UI deletion
  # + re-apply leaves the new container running without Pi-hole.
  triggers = {
    script_sha    = sha256(local.pihole_install_script)
    container_mac = module.lxc.primary_mac_address
  }

  connection {
    type        = "ssh"
    host        = local.pihole_host_ipv4
    user        = "root"
    private_key = file(pathexpand(var.operator_ssh_private_key_path))
    timeout     = "2m"
    # Empty host_key disables strict host-key checking. The LXC's host
    # key isn't known until first boot; this avoids manual
    # ssh-keyscan before the very first apply. Acceptable for a
    # single-operator LAN-only homelab.
    host_key = ""
  }

  provisioner "file" {
    content     = local.pihole_install_script
    destination = "/root/pi-hole-bootstrap.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "bash /root/pi-hole-bootstrap.sh",
      "rm -f /root/pi-hole-bootstrap.sh",
    ]
  }

  depends_on = [module.lxc]
}

output "pihole_host_ipv4" {
  description = "Pi-hole container IPv4 (CIDR stripped)."
  value       = local.pihole_host_ipv4
}

output "pihole_vm_id" {
  description = "Proxmox VM ID of the Pi-hole container."
  value       = module.lxc.vm_id
}
