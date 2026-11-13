variable "account_id" {
  description = "Cloudflare account ID, the tunnel's owner."
  type        = string
}

variable "joelst_zone" {
  description = "joelst's zone, e.g. example.com. The apex is the site."
  type        = string
}

variable "joelst_zone_id" {
  description = "Cloudflare zone ID of joelst_zone."
  type        = string
}

variable "metachat_zone" {
  description = "metachat's zone, e.g. example.net. The site is chat.<zone>."
  type        = string
}

variable "metachat_zone_id" {
  description = "Cloudflare zone ID of metachat_zone."
  type        = string
}
