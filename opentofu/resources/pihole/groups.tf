# Pi-hole groups, managed as a set so adding one is a single entry in
# var.pihole_groups rather than a new resource block.
#
# "Default" is deliberately absent: Pi-hole ships it as group ID 0, it
# exists whether or not we declare it, and destroying it would orphan
# every client not explicitly assigned elsewhere. var.pihole_groups
# rejects it; clients still reference it by name.
resource "pihole_group" "managed" {
  for_each = var.pihole_groups

  name        = each.key
  description = each.value
  enabled     = true

  depends_on = [null_resource.pihole_ready]
}

# Exclusions predates the for_each and lived in adlists.tf as its own
# resource. Rename in place — without this, the switch destroys the
# group and recreates it with a fresh ID, and every client assignment
# pointing at the old ID goes with it.
moved {
  from = pihole_group.exclusions
  to   = pihole_group.managed["Exclusions"]
}

locals {
  # pihole_client.groups takes numeric group IDs, not names, so callers
  # can't reference a group by the name they declared it under. Map the
  # two: "Default" is Pi-hole's built-in 0, everything else is computed
  # after the group is applied.
  group_ids = merge(
    { Default = 0 },
    { for name, group in pihole_group.managed : name => group.id },
  )
}
