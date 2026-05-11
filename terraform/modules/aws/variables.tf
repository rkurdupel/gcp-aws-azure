variable "config" {
  type = any
}

variable "ssh_public_key" {
  type = string
}

variable "cloudflare_zone_id" {
  type = string
}

variable "db_name" {
  type = string
}

variable "db_user" {
  type = string
}

variable "db_password" {
  type = string
  sensitive = true
}

variable "domain_name" {
  type = string
}