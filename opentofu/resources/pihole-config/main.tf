# pihole-01's own address, never the VIP: the VIP can sit on pihole-02, where
# nebula-sync overwrites anything written. kubernetes/clusters/homelab/nebula-sync names the
# same primary.
data "netbox_virtual_machines" "primary" {
  name_regex = "^pihole-01$"
  limit      = 100

  lifecycle {
    postcondition {
      condition     = try(strcontains(self.vms[0].primary_ip4, "/"), false)
      error_message = "NetBox has no VM named 'pihole-01' with a primary IPv4 in CIDR form."
    }
  }
}

locals {
  pihole_host_ipv4 = split("/", data.netbox_virtual_machines.primary.vms[0].primary_ip4)[0]
}
