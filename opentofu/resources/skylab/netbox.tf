# Skylab's NetBox record. Its site is the apply gate: main places it outside
# the EU, the NetBox branch at an EU site (docs/design/skylab-provisioning.md).
data "netbox_virtual_machines" "skylab" {
  name_regex = "(?i)^skylab$"
  limit      = 100

  lifecycle {
    postcondition {
      condition     = length(self.vms) == 1
      error_message = "NetBox must hold exactly one VM named 'skylab'; it holds ${length(self.vms)}."
    }
  }
}

locals {
  nb_vm = data.netbox_virtual_machines.skylab.vms[0]
}

data "netbox_site" "skylab" {
  id = local.nb_vm.site_id
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
