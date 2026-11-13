# hcloud reads HCLOUD_TOKEN from this directory's secrets.env.
provider "hcloud" {}

provider "netbox" {
  server_url = var.netbox_url
  api_token  = var.netbox_token
  # The provider's own NETBOX_HEADERS default fails on a map-typed value.
  headers = var.netbox_headers
}
