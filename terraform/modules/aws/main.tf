locals {
  cloud = lookup(var.config, "cloud", "aws")
}

# Register the public SSH key in AWS EC2 (VM) as a key pair named after the VM
resource "aws_key_pair" "this" {
    key_name = "${lookup(var.config, "name_prefix", "coinops")}-ssh-key"
    public_key = var.ssh_public_key
}

# find real aws image for each vm
# ubuntu_2404 - input
data "aws_ami" "selected" {
  for_each    = var.config.instances
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
  availability_zone = lookup(var.config.zone_map.aws, "first", "eu-central-1a")
  private_subnetwork_cidr = lookup(var.config.network, "private_subnetwork_cidr", "10.10.1.0/24")

   # ALB requires at least two public subnets in different Availability Zones
  second_public_subnet_cidr = lookup(var.config.network, "second_public_subnet_cidr", "10.10.2.0/24")
  second_availability_zone = lookup(var.config.zone_map.aws, "second", "eu-central-1b")
}



module "firewall" {
  source       = "./firewall"
  network_name = lookup(var.config.network, "name", "coinops-network")
  network_id   = module.network.network_id
  ports        = tonumber(lookup(var.config.ssh, "port", 22))
  protocol     =  lookup(var.config.ssh, "protocol", "tcp")
  cidr         = lookup(var.config.firewall, "ssh_source_ranges", ["0.0.0.0/0"])[0]
}


module "vm" {
  source   = "./vm"
  for_each = lookup(var.config, "instances", {})

  key_name = aws_key_pair.this.key_name

  name = each.key
  ami  = data.aws_ami.selected[each.key].id

  instance_type = lookup(
    lookup(var.config.instance_type_map, lookup(each.value, "size", var.config.defaults.size), {}),
    local.cloud,
    "t3.micro"
  )

  tags       = lookup(each.value, "tags", [])
  subnet_id  =  contains(lookup(each.value, "tags", []), "bastion") ? module.network.subnet_id : module.network.private_subnet_id
  public_ip  = lookup(each.value, "public", false)
  private_ip = lookup(each.value, "private_ip", null)
  # if bastion - bastion , if db - db group else private group
  security_group_id = contains(lookup(each.value, "tags", []), "bastion") ? [
  module.firewall.bastion_security_group_id
  ] : contains(lookup(each.value, "tags", []), "db") ? [
    module.firewall.db_security_group_id
  ] : [
    module.firewall.private_security_group_id
  ]
  ssh_public_key = var.ssh_public_key
  ssh_user       = lookup(var.config.ssh, "user", "ubuntu")
  ssh_port       = tonumber(lookup(var.config.ssh, "port", 22))
}


module "load_balancer" {
  source = "./load_balancer"

  network_name = lookup(var.config.network, "name", "coinops-network")
  vpc_id = module.network.network_id
  public_subnet_ids = module.network.public_subnet_ids
  security_group_id = module.firewall.lb_security_group_id
  health_check_path = "/health"
  app_port = 80
}

# attach each app vm to the alb target group
resource "aws_lb_target_group_attachment" "app" {
  for_each = {
    for name, vm in module.vm : name => vm
    if contains(lookup(var.config.instances[name], "tags", []), "app")
    # keep only vms whose. tags contain app
  }

  target_group_arn = module.load_balancer.target_group_arn  # arn - amazon resource name 
  target_id        = each.value.instance_id
  port             = 80
}


# create a dns record in cloudflare (coin-ops.pp.ua => coinops-network-812317851.eu-central-1.elb.amazonaws.com)
resource "cloudflare_record" "app" {
  zone_id = var.cloudflare_zone_id
  name = "@"  # app.coin-ops.pp.ua
  type = "CNAME"  # if target is another domain / name - cname
  content = module.load_balancer.alb_dns_name # coin-ops.pp.ua => coinops-network-812317851.eu-central-1.elb.amazonaws.com
  ttl = 60  # dns cache time 60 seconds (user opens app.coin-ops.pp.ua => dns resolver asks cloudflare where to go it redirects to alb and saves that answer for 60 sec)
  proxied = false
}