locals {
  # Plain HTTP inside the cluster: an origin that redirects to HTTPS loops.
  joelst_origin   = "http://joelst.joelst.svc.cluster.local:8080"
  metachat_origin = "http://metachat.metachat.svc.cluster.local:8080"

  # One tunnel route and one proxied record per entry. www has its own,
  # because joelst's nginx redirects it to the apex by Host.
  hostnames = {
    joelst     = { zone_id = var.joelst_zone_id, name = var.joelst_zone, service = local.joelst_origin }
    joelst-www = { zone_id = var.joelst_zone_id, name = "www.${var.joelst_zone}", service = local.joelst_origin }
    metachat   = { zone_id = var.metachat_zone_id, name = "metachat.${var.metachat_zone}", service = local.metachat_origin }

    # The cutover gate's test names, one label deep so the edge certificate covers them.
    joelst-next   = { zone_id = var.joelst_zone_id, name = "next.${var.joelst_zone}", service = local.joelst_origin }
    metachat-next = { zone_id = var.metachat_zone_id, name = "metachat-next.${var.metachat_zone}", service = local.metachat_origin }
  }

  tunnel_cname = "${cloudflare_zero_trust_tunnel_cloudflared.skylab.id}.cfargotunnel.com"
}

# A type change replaces the record, deleting before creating, so one address
# per name keeps an A and a CNAME of the same name from coexisting.
resource "cloudflare_dns_record" "hostname" {
  for_each = local.hostnames

  zone_id = each.value.zone_id
  name    = each.value.name
  type    = contains(keys(var.ashburn_record_ids), each.key) ? "A" : "CNAME"
  content = contains(keys(var.ashburn_record_ids), each.key) ? var.ashburn_ipv4 : local.tunnel_cname
  proxied = true
  ttl     = 1
  comment = "opentofu"
}
