# The same three lookups as modules/k8s-vm/main.tf, for the same reason.
data "netbox_virtual_machines" "match" {
  filters = [{ name = "name", value = var.name }]

  lifecycle {
    postcondition {
      condition     = try(self.virtual_machines[0].primary_ip4_id, null) != null
      error_message = "NetBox has no VM named '${var.name}' with a primary IPv4. Model it in NetBox first; without an address the container would fall back to DHCP."
    }
    # The per-NUC dir decides the node; a NetBox placement elsewhere fails the plan.
    postcondition {
      condition     = try(self.virtual_machines[0].device_id, null) != null
      error_message = "NetBox places '${var.name}' on no device but this call placed it on '${var.node_name}'. Update NetBox or move the module call to the matching per-NUC dir."
    }
  }
}

data "netbox_device" "host" {
  id = local.nb_vm.device_id

  lifecycle {
    postcondition {
      condition     = self.name == var.node_name
      error_message = "NetBox places '${var.name}' on '${self.name}' but this call placed it on '${var.node_name}'. Update NetBox or move the module call to the matching per-NUC dir."
    }
  }
}

data "netbox_ip_address" "primary4" {
  id = local.nb_vm.primary_ip4_id

  lifecycle {
    postcondition {
      condition     = strcontains(self.ip_address, "/")
      error_message = "NetBox's primary IPv4 for '${var.name}' is not in CIDR form."
    }
  }
}
