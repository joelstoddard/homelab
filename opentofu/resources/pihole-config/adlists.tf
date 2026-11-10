# Adlists. Groups live in ./groups.tf, clients in ./clients.tf.

resource "pihole_list" "block" {
  for_each = toset(var.pihole_adlists)

  address = each.value
  type    = "block"
  enabled = true
  comment = "Managed by OpenTofu (pihole_adlists var)."
}

# The Pi-hole installer seeds this list on every fresh instance, and the API
# refuses a second list with the same address. Adopting it leaves the
# instance holding exactly var.pihole_adlists.
import {
  for_each = setintersection(toset(var.pihole_adlists), ["https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"])

  to = pihole_list.block[each.value]
  id = "block/${each.value}"
}

# Rebuild gravity and make FTL reload it when the list set changes. Adding a
# list through the API only writes the adlist table; FTL keeps serving the
# domains it loaded at startup.
resource "null_resource" "gravity_apply" {
  # List IDs rather than URLs, so a rebuilt pihole-01, whose lists come back
  # under new IDs, gets its gravity rebuilt too.
  triggers = {
    list_ids = join(",", sort([for list in pihole_list.block : tostring(list.id)]))
  }

  connection {
    type        = "ssh"
    host        = local.pihole_host_ipv4
    user        = "root"
    private_key = file(pathexpand(var.operator_ssh_private_key_path))
    timeout     = "1m"
    # The container's host key changes on every rebuild. Acceptable for a
    # single-operator, LAN-only homelab.
    host_key = ""
  }

  provisioner "remote-exec" {
    inline = [
      "pihole -g",
      "systemctl restart pihole-FTL",
    ]
  }
}
