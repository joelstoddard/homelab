# Client registrations. The whole client set — names as well as MACs —
# lives in this directory's SOPS-encrypted secrets.env, because on a
# public repo a Pi-hole client list is a household device inventory.
# See var.pihole_clients.
resource "pihole_client" "managed" {
  # for_each over the keys alone. var.pihole_clients is sensitive and
  # OpenTofu refuses sensitive for_each arguments outright (they'd
  # surface as resource instance addresses). The keys are device names,
  # secret by repo policy rather than by taint-tracking, so unwrapping
  # just those is sound — every MAC read below stays sensitive and
  # renders as "(sensitive value)" in plan output.
  for_each = toset(nonsensitive(keys(var.pihole_clients)))

  # Pi-hole stores the client identifier verbatim and its API matches it
  # case-sensitively, so "aa:bb:…" and "AA:BB:…" are two distinct clients
  # rather than one. Normalise to uppercase — the case Pi-hole's own UI
  # writes — so a lowercase secrets.env entry updates the existing client
  # instead of creating a duplicate beside it.
  client  = upper(var.pihole_clients[each.key].mac)
  comment = each.key
  groups  = [for name in var.pihole_clients[each.key].groups : local.group_ids[name]]

  depends_on = [null_resource.pihole_ready]
}

# Pi-hole enforces blocking when a client is in *any* group owning the
# matched list, so a client in both Default and Exclusions is still
# blocked by Default's lists — the bypass silently does nothing. Warn
# rather than fail: the config is valid, just not what the operator
# almost certainly meant.
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
