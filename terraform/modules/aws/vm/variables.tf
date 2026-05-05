variable "ami" {
  type = string
}
variable "instance_type" {
  type = string
}
variable "subnet_id" {
  type = string
}
variable "name" {
  type = string
}
variable "tags" {
  type = list(string)
}
variable "public_ip" {
  type = bool
}
variable "private_ip" {
  type    = string
  default = null
}
variable "security_group_id" {
  type = list(string)
}
variable "ssh_public_key" {
  type = string
}
variable "ssh_user" {
  type = string
}
variable "ssh_port" {
  type = number
}

variable "key_name" {
  type = string
}

