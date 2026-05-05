locals {
  cloud = lookup(var.config, "cloud", "aws")
}

# Register the public SSH key in AWS EC2 (VM) as a key pair named after the VM
resource "aws_key_pair" "this" {
    key_name   = "${lookup(var.config.project, "name", "coinops")}-${lookup(var.config.project, "environment", "dev")}-ssh-key"
    public_key = var.ssh_public_key
}

# find real aws image for each vm
# ubuntu_2404 - input
data "aws_ami" "selected" {
  for_each    = var.config.vms
  most_recent = true # choose the newest model

  # search images from truster owner
  owners = [
    var.config.image_map[lookup(each.value, "image", var.config.defaults.image)].aws.owner
  ]

  # find image  by name pattern (ubuntu 24.04)
  filter {
    name = "name" # filter by name
    values = [
      var.config.image_map[lookup(each.value, "image", var.config.defaults.image)].aws.name_pattern
    ]
  }
  # use only x86_64
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

module "network" {
  source            = "./network"
  network_cidr      = lookup(var.config.network, "cidr", "10.10.0.0/16")
  subnetwork_cidr   = lookup(var.config.network, "subnet_cidr", "10.10.0.0/24")
  dns_support       = lookup(var.config.network, "aws_dns_support", true)
  dns_hostnames     = lookup(var.config.network, "aws_dns_hostnames", true)
  network_name      = lookup(var.config.network, "name", "coinops-network")
  subnetwork_name   = lookup(var.config.network, "subnet_name", "coinops-subnet")
  availability_zone = lookup(var.config.zone_map, local.cloud, "eu-central-1a")
}



module "firewall" {
  source       = "./firewall"
  network_name = lookup(var.config.network, "name", "coinops-network")
  network_id   = module.network.network_id
  ports        = tonumber(lookup(var.config.ssh, "port", 22))
  protocol     = lookup(var.config.firewall.bastion_ssh, "protocol", "tcp")
  cidr         = lookup(var.config.firewall.bastion_ssh.sources, "cidrs", ["0.0.0.0/0"])[0]
}


module "vm" {
  source   = "./vm"
  for_each = lookup(var.config, "vms", {})

  key_name = aws_key_pair.this.key_name

  name = each.key
  ami  = data.aws_ami.selected[each.key].id

  instance_type = lookup(
    lookup(var.config.instance_type_map, lookup(each.value, "size", var.config.defaults.size), {}),
    local.cloud,
    "t3.micro"
  )

  tags       = lookup(each.value, "tags", [])
  subnet_id  = module.network.subnet_id
  public_ip  = lookup(each.value, "public", false)
  private_ip = lookup(each.value, "private_ip", null)
  # is bastion set security group for bastion any other tag - private
  security_group_id = contains(lookup(each.value, "tags", []), "bastion") ? [
    module.firewall.bastion_security_group_id
    ] : [
    module.firewall.private_security_group_id
  ]

  ssh_public_key = var.ssh_public_key
  ssh_user       = lookup(var.config.ssh, "user", "ubuntu")
  ssh_port       = tonumber(lookup(var.config.ssh, "port", 22))
}



