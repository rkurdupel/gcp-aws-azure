variable "network_name" {
    type = string
}

variable "vpc_id" {
    type = string
}

variable "public_subnet_ids" {
    type = list(string)
}

variable "security_group_id" {
    type = string
}

variable "health_check_path" {
    type = string
}

variable "app_port" {
    type =  number
}