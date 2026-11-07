# Filtered client-side after `limit` applies; see modules/k8s-vm/main.tf.
data "netbox_virtual_machines" "match" {
  name_regex = "^${var.name}$"
  limit      = 100

  lifecycle {
    postcondition {
      condition     = try(strcontains(self.vms[0].primary_ip4, "/"), false)
      error_message = "NetBox has no VM named '${var.name}' with a primary IPv4 in CIDR form. Model it in NetBox first; without an address the container would fall back to DHCP."
    }
  }
}
