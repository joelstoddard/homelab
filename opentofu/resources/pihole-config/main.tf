# pihole-01's own address, never the VIP: the VIP can sit on pihole-02, where
# nebula-sync overwrites anything written. kubernetes/clusters/homelab/nebula-sync names the
# same primary.
data "netbox_virtual_machines" "primary" {
  filters = [{ name = "name", value = "pihole-01" }]

  lifecycle {
    postcondition {
      condition     = try(self.virtual_machines[0].primary_ip4_id, null) != null
      error_message = "NetBox has no VM named 'pihole-01' with a primary IPv4."
    }
  }
}

data "netbox_ip_address" "primary" {
  id = data.netbox_virtual_machines.primary.virtual_machines[0].primary_ip4_id

  lifecycle {
    postcondition {
      condition     = strcontains(self.ip_address, "/")
      error_message = "NetBox's primary IPv4 for 'pihole-01' is not in CIDR form."
    }
  }
}

locals {
  pihole_host_ipv4 = split("/", data.netbox_ip_address.primary.ip_address)[0]
}
