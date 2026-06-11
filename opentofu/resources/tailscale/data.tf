# Validate that the advertised subnet exists in NetBox IPAM (source of truth).
# Fails at plan time if the prefix hasn't been created in NetBox yet.
data "netbox_prefix" "advertised" {
  prefix = var.tailscale_advertised_cidr
}

# Look up the Proxmox node's primary IP from NetBox so pct commands
# run on the node that actually hosts the container.
# pct is node-local — it cannot manage containers on other cluster members.
data "netbox_devices" "node" {
  filter {
    name  = "name"
    value = var.tailscale_node
  }
}
