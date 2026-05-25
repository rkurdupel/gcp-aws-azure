variable "config" {
  type = any
}

variable "ssh_public_key" {
  type = string
}

variable "instances" {
  type    = any
  default = null
}

variable "cloudflare_zone_id" {
  type = string
}