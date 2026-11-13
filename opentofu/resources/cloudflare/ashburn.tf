# The records Ashburn serves, imported as they are. The cutover PR deletes
# this file (docs/design/skylab-ingress.md, "Records: imported, then switched").

variable "ashburn_ipv4" {
  description = "Ashburn's public IPv4, the live records' content until cutover."
  type        = string
  sensitive   = true
}

variable "ashburn_record_ids" {
  description = "Cloudflare record ID of each live record, keyed by its local.hostnames key."
  type        = map(string)
}

import {
  for_each = var.ashburn_record_ids
  to       = cloudflare_dns_record.hostname[each.key]
  id       = "${local.hostnames[each.key].zone_id}/${each.value}"
}
