# hcloud and cloudflare read HCLOUD_TOKEN and CLOUDFLARE_API_TOKEN from this
# directory's secrets.env.
provider "hcloud" {}

provider "cloudflare" {}

provider "netbox" {
  server_url = var.netbox_url
  api_token  = var.netbox_token
  # The provider's own NETBOX_HEADERS default fails on a map-typed value.
  headers = var.netbox_headers
}
