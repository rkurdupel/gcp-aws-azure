locals {
  cloud = lookup(var.config, "cloud", "gcp")
}

module "network" {
  source = "./network"

  network_name            = lookup(var.config.network, "name", "coinops-network")
  subnetwork_name         = lookup(var.config.network, "subnet_name", "coinops-subnet")
  subnetwork_cidr         = lookup(var.config.network, "subnet_cidr", "10.10.0.0/24")
  auto_create_subnetworks = lookup(var.config.network, "gcp_auto_create_subnetworks", false)
}



module "firewall" {
  for_each = lookup(var.config, "firewall", {})
  source   = "./firewall"

  name          = replace(each.key, "_", "-") # bastion_ssh to bastion-ssh
  network_id    = module.network.network_id
  direction     = lookup(each.value, "direction", "INGRESS")
  source_ranges = lookup(lookup(each.value, "sources", {}), "cidrs", [])
  source_tags   = lookup(lookup(each.value, "sources", {}), "groups", [])
  target_tags   = lookup(lookup(each.value, "targets", {}), "groups", [])
  protocol      = lookup(each.value, "protocol", "tcp")
  # convert to string
  ports = lookup(each.value, "ports", [tostring(lookup(var.config.ssh, "port", 22))])
}

module "vm" {
  source   = "./vm"
  for_each = lookup(var.config, "vms", {}) # looping vm block from config
  name     = each.key                      #  name of the vm from so config (bastion, private-1)
  zone     = lookup(var.config.zone_map, local.cloud, "europe-central2-a")
  machine_type = lookup(
    lookup(var.config.instance_type_map, lookup(each.value, "size", var.config.defaults.size), {}),
    local.cloud,
    "e2-micro"
  )
  tags           = lookup(each.value, "tags", [])
  public_ip      = lookup(each.value, "public", false)
  private_ip     = lookup(each.value, "private_ip", null)
  ssh_user       = lookup(var.config.ssh, "user", "ubuntu")
  ssh_port       = tonumber(lookup(var.config.ssh, "port", 22))
  ssh_public_key = var.ssh_public_key
  boot_image = lookup(
    lookup(var.config.image_map, lookup(each.value, "image", var.config.defaults.image), {}),
    local.cloud,
    "projects/ubuntu-os-cloud/global/images/family/ubuntu-2404-lts-amd64"
  )
  size_gb              = lookup(each.value, "disk_size_gb", lookup(var.config.defaults, "disk_size_gb", 20))
  subnetwork_self_link = module.network.subnetwork_self_link
}
