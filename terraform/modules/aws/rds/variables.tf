variable "network_name" {
    type = string
}

variable "vpc_id" {
    type = string
}

variable "private_subnet_ids" {
    type = list(string)
}

variable "app_security_group_id" {
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
    sensitive = true    # hide value in terminal output (during terraform plan/apply)
    
}