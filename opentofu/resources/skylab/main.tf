# Every billable resource carries the gate's count, so a run against NetBox
# main plans nothing (docs/design/skylab-provisioning.md).

# The snapshot `make -C opentofu skylab-image` uploads; the newest wins, so a
# versions.env bump never leaves the plan without an image.
data "hcloud_images" "talos" {
  count             = local.in_eu ? 1 : 0
  with_selector     = "talos_schematic=${var.talos_skylab_schematic_id}"
  with_architecture = ["x86"]
  most_recent       = true

  lifecycle {
    postcondition {
      condition     = length(self.images) > 0
      error_message = "No snapshot labelled talos_schematic=${var.talos_skylab_schematic_id}. Run 'make -C opentofu skylab-image' first."
    }
  }
}

data "hcloud_server_type" "skylab" {
  name = "cx33"
}

resource "hcloud_primary_ip" "ipv4" {
  count             = local.in_eu ? 1 : 0
  name              = "skylab-ipv4"
  type              = "ipv4"
  location          = local.location
  auto_delete       = false
  delete_protection = true
}

resource "hcloud_firewall" "skylab" {
  count = local.in_eu ? 1 : 0
  name  = "skylab"

  rule {
    description = "TURN"
    direction   = "in"
    protocol    = "tcp"
    port        = "3478"
    source_ips  = ["0.0.0.0/0"]
  }

  rule {
    description = "TURN"
    direction   = "in"
    protocol    = "udp"
    port        = "3478"
    source_ips  = ["0.0.0.0/0"]
  }

  rule {
    description = "TURN relay"
    direction   = "in"
    protocol    = "udp"
    port        = "49160-49500"
    source_ips  = ["0.0.0.0/0"]
  }

  rule {
    description = "ICMP"
    direction   = "in"
    protocol    = "icmp"
    source_ips  = ["0.0.0.0/0"]
  }
}

resource "hcloud_server" "skylab" {
  count       = local.in_eu ? 1 : 0
  name        = "skylab"
  server_type = data.hcloud_server_type.skylab.name
  location    = local.location
  image       = tostring(data.hcloud_images.talos[0].images[0].id)
  # The talos role's render: make -C ansible apply-talos CLUSTER=skylab TAGS=config.
  user_data    = file("${path.module}/../../../ansible/.talos/skylab/skylab-${local.nb_vm.name}.yaml")
  firewall_ids = [hcloud_firewall.skylab[0].id]

  delete_protection  = true
  rebuild_protection = true

  public_net {
    ipv4_enabled = true
    ipv4         = hcloud_primary_ip.ipv4[0].id
    ipv6_enabled = false
  }

  # Both are ForceNew; Talos upgrades in place (docs/design/skylab-upgrades.md).
  lifecycle {
    ignore_changes = [image, user_data]
  }
}

# Forgejo's repositories (docs/design/skylab-forgejo.md, "Storage"). The
# separate attachment re-attaches the same Volume to a rebuilt server.
resource "hcloud_volume" "forgejo" {
  count    = local.in_eu ? 1 : 0
  name     = "forgejo"
  size     = 10
  location = local.location

  lifecycle {
    prevent_destroy = true
  }
}

resource "hcloud_volume_attachment" "forgejo" {
  count     = local.in_eu ? 1 : 0
  volume_id = hcloud_volume.forgejo[0].id
  server_id = hcloud_server.skylab[0].id
}

# Checks warn and never block the apply.
check "netbox_sizing" {
  assert {
    condition = !local.in_eu || (
      local.nb_vm.vcpus == data.hcloud_server_type.skylab.cores &&
      local.nb_vm.memory_mb == data.hcloud_server_type.skylab.memory * 1000 &&
      local.nb_vm.disk_size_mb == data.hcloud_server_type.skylab.disk * 1000
    )
    error_message = "NetBox sizes skylab at ${local.nb_vm.vcpus} vCPU / ${local.nb_vm.memory_mb} MB / ${local.nb_vm.disk_size_mb} MB, but cx33 is ${data.hcloud_server_type.skylab.cores} / ${data.hcloud_server_type.skylab.memory * 1000} / ${data.hcloud_server_type.skylab.disk * 1000}. Update one to match the other."
  }
}

check "netbox_primary_ipv4" {
  assert {
    condition     = !local.in_eu || try(split("/", local.nb_vm.primary_ip4)[0] == hcloud_primary_ip.ipv4[0].ip_address, false)
    error_message = "NetBox's primary IPv4 for skylab is not the Hetzner primary IP. Enter the address on the branch record after apply."
  }
}
