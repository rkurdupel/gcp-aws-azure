variable "name" {
  type = string
}

variable "zone" {
  type = string
}

variable "machine_type" {
  type = string
}

variable "tags" {
  type = list(string)
}

variable "public_ip" {
  type = bool
}

variable "ssh_user" {
  type = string
}

variable "ssh_port" {
  type = number
}

variable "ssh_public_key" {
  type = string
}

variable "boot_image" {
  type = string
}

variable "size_gb" {
  type = number
}

variable "subnetwork_self_link" {
  type = string
}

variable "private_ip" {
  type = string
}