locals {
  node_ssh_host = coalesce(
    var.proxmox_ssh_host,
    split("/", data.netbox_devices.node.devices[0].primary_ipv4)[0],
  )

  tailscale_install_script = file("${path.module}/templates/install.sh.tftpl")
}
