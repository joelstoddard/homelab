# "Default" is Pi-hole's built-in group 0 and is never managed here:
# destroying it would orphan every unassigned client.
resource "pihole_group" "managed" {
  for_each = var.pihole_groups

  name        = each.key
  description = each.value
  enabled     = true
}

locals {
  # pihole_client takes numeric group IDs, so map each declared name to its
  # ID, with Default as 0.
  group_ids = merge(
    { Default = 0 },
    { for name, group in pihole_group.managed : name => group.id },
  )
}
