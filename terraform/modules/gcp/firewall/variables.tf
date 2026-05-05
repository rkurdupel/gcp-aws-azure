variable "name" {
  type = string
}

variable "network_id" {
  type = string
}

variable "direction" {
  type = string
}

variable "source_ranges" {
  type = list(string)
}

variable "source_tags" {
  type = list(string)
}

variable "target_tags" {
  type = list(string)
}

variable "protocol" {
  type = string
}

variable "ports" {
  type = list(string)
}