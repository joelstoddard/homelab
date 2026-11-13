# Filtered client-side after `limit` applies; see modules/k8s-vm/main.tf.
data "netbox_virtual_machines" "match" {
  name_regex = "^${var.name}$"
  limit      = 100

  lifecycle {
    postcondition {
      condition     = try(strcontains(self.vms[0].primary_ip4, "/"), false)
      error_message = "NetBox has no VM named '${var.name}' with a primary IPv4 in CIDR form. Model it in NetBox first; without an address the container would fall back to DHCP."
    }
    # The per-NUC dir decides the node; a NetBox placement elsewhere fails the plan.
    postcondition {
      condition     = try(self.vms[0].device_name, null) == var.node_name
      error_message = "NetBox places '${var.name}' on '${try(coalesce(self.vms[0].device_name, "(no device)"), "(missing)")}' but this call placed it on '${var.node_name}'. Update NetBox or move the module call to the matching per-NUC dir."
    }
  }
}
