# Skylab's NetBox record. Its site is the apply gate: main places it outside
# the EU, the NetBox branch at an EU site (docs/design/skylab-provisioning.md).
data "netbox_virtual_machines" "skylab" {
  filters = [{ name = "name__ie", value = "skylab" }]

  lifecycle {
    postcondition {
      condition     = length(self.virtual_machines) == 1
      error_message = "NetBox must hold exactly one VM named 'skylab'; it holds ${length(self.virtual_machines)}."
    }
  }
}

locals {
  nb_vm = data.netbox_virtual_machines.skylab.virtual_machines[0]
}

data "netbox_site" "skylab" {
  id = local.nb_vm.site_id
}

# Optional: the netbox_primary_ipv4 check warns while it is unset.
data "netbox_ip_address" "skylab" {
  count = local.nb_vm.primary_ip4_id == null ? 0 : 1
  id    = local.nb_vm.primary_ip4_id
}

data "hcloud_locations" "all" {}

locals {
  # The EU location whose city is the NetBox site's name, else null.
  location = one([
    for l in data.hcloud_locations.all.locations : l.name
    if l.network_zone == "eu-central" && l.city == data.netbox_site.skylab.name
  ])
  in_eu = local.location != null
}
