variable "network_cidr" {
  type = string
}

variable "dns_support" {
  type = bool
}

variable "dns_hostnames" {
  type = bool
}

variable "network_name" {
  type = string
}

variable "subnetwork_name" {
  type = string
}

variable "subnetwork_cidr" {
  type = string
}

variable "availability_zone" {
  type = string
}

variable "private_subnetwork_cidr" {
  type = string
}

variable "second_public_subnet_cidr" { 
  type = string 
}
variable "second_availability_zone"  { 
  type = string 
}

variable "private_subnetwork_2_cidr" {
  type = string
}