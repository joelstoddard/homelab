# Clients placed exclusively (and only) in this group bypass all
# adlist-driven blocking. See ./README.md for the group-membership
# caveat: a client also in "Default" will still be blocked by
# Default-group lists.
resource "pihole_group" "exclusions" {
  name        = "Exclusions"
  description = "Clients in this group bypass all ad-blocking."
  enabled     = true

  depends_on = [null_resource.pihole_ready]
}

resource "pihole_list" "block" {
  for_each = toset(var.pihole_adlists)

  address = each.value
  type    = "block"
  enabled = true
  comment = "Managed by OpenTofu (pihole_adlists var)."

  depends_on = [null_resource.pihole_ready]
}

# Rebuild gravity + force FTL to reload its in-memory domain table when
# the adlist set changes. Without this, adding/removing pihole_list
# resources updates the gravity.db (which Pi-hole's CLI calls "gravity"),
# but FTL keeps serving from the snapshot it loaded at startup —
# blocking behavior stops matching declared state.
resource "null_resource" "gravity_apply" {
  # Trigger on both the adlist set AND null_resource.pihole_install's
  # id. The latter changes whenever the installer re-runs (which
  # itself triggers on container recreation), so a Proxmox-UI deletion
  # of the LXC followed by re-apply rebuilds gravity on the fresh
  # Pi-hole — not just when adlists are edited.
  triggers = {
    adlists_sha = sha256(jsonencode(sort(var.pihole_adlists)))
    install_id  = null_resource.pihole_install.id
  }

  connection {
    type        = "ssh"
    host        = local.pihole_host_ipv4
    user        = "root"
    private_key = file(pathexpand(var.operator_ssh_private_key_path))
    timeout     = "1m"
    # See main.tf:null_resource.pihole_install for the host_key=""
    # rationale (LAN-only single-operator homelab).
    host_key = ""
  }

  # `pihole -g` rebuilds gravity from the adlists; the systemctl
  # restart drops FTL's stale in-memory snapshot so the rebuilt
  # gravity actually takes effect on the next DNS query.
  provisioner "remote-exec" {
    inline = [
      "pihole -g",
      "systemctl restart pihole-FTL",
    ]
  }

  depends_on = [pihole_list.block]
}
