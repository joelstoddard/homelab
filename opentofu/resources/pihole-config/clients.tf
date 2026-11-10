# Client registrations. Names and MACs both live in the SOPS-encrypted
# secrets.env, because a client list is a household device inventory.
resource "pihole_client" "managed" {
  # OpenTofu refuses a sensitive for_each, so only the keys are unwrapped;
  # every MAC read below stays sensitive in plan output.
  for_each = toset(nonsensitive(keys(var.pihole_clients)))

  # Pi-hole matches the identifier case-sensitively, so a lowercase MAC would
  # register a second client beside the one its UI wrote in uppercase.
  client  = upper(var.pihole_clients[each.key].mac)
  comment = each.key
  groups  = [for name in var.pihole_clients[each.key].groups : local.group_ids[name]]
}

# A client in both Default and Exclusions is still blocked by Default's
# lists, so the bypass silently does nothing. A warning, because the config
# is valid.
check "exclusions_are_exclusive" {
  assert {
    condition = alltrue([
      for name in nonsensitive(keys(var.pihole_clients)) :
      !(contains(nonsensitive(var.pihole_clients[name].groups), "Exclusions") &&
      contains(nonsensitive(var.pihole_clients[name].groups), "Default"))
    ])
    error_message = "A client is in both Default and Exclusions. Default's adlists still block it — drop \"Default\" from that client's groups in secrets.env for the bypass to take effect."
  }
}
