locals {
  pihole_host_ipv4 = split("/", var.pihole_static_ipv4_cidr)[0]

  # Wildcard the root domain at the cluster ingress, then hand back the
  # handful of names that are really hosted elsewhere. dnsmasq matches the
  # most specific domain first, so the server= lines win over the address=
  # line. Both inputs empty (an unpopulated checkout) means an empty array,
  # which clears the setting rather than half-configuring it.
  pihole_dnsmasq_lines = (
    var.pihole_wildcard_domain == "" || var.pihole_cluster_ingress_ip == ""
    ? []
    : concat(
      ["address=/${var.pihole_wildcard_domain}/${var.pihole_cluster_ingress_ip}"],
      [for name in var.pihole_dns_passthrough_names : "server=/${name}/#"],
    )
  )

  pihole_install_script = templatefile("${path.module}/templates/install.sh.tftpl", {
    static_ipv4_cidr   = var.pihole_static_ipv4_cidr
    dns_1              = var.pihole_upstream_dns[0]
    dns_2              = length(var.pihole_upstream_dns) > 1 ? var.pihole_upstream_dns[1] : ""
    web_password       = var.pihole_web_password
    dnsmasq_lines_json = jsonencode(local.pihole_dnsmasq_lines)
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
  # Both inputs empty is legitimate — an unpopulated checkout. One empty is
  # always a mistake, and the `[]` fallback above turns it into an apply that
  # reports success and writes nothing: a misspelled TF_VAR_ name in
  # secrets.env cost a full rollout round that way. Fail at plan time instead.
  lifecycle {
    precondition {
      condition     = (var.pihole_wildcard_domain == "") == (var.pihole_cluster_ingress_ip == "")
      error_message = "pihole_wildcard_domain and pihole_cluster_ingress_ip must be set together or left empty together — one without the other silently disables the cluster wildcard. Check the TF_VAR_ names in opentofu/resources/pihole/secrets.env."
    }

    precondition {
      condition     = length(var.pihole_dns_passthrough_names) == 0 || var.pihole_wildcard_domain != ""
      error_message = "pihole_dns_passthrough_names is set while pihole_wildcard_domain is empty: there is no wildcard for those names to override, so the server= lines they generate would pass through names nothing was catching."
    }
  }

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

  # One command, not two. remote-exec joins an inline list into a single
  # script with no `set -e`, so the provisioner's exit status is the LAST
  # command's: a failed installer followed by a succeeding `rm` reported
  # "Apply complete!" while nothing had been configured. The script now
  # deletes itself via an EXIT trap instead.
  provisioner "remote-exec" {
    inline = [
      "bash /root/pi-hole-bootstrap.sh",
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
