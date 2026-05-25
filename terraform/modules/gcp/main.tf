locals {
  cloud = "gcp"
}

module "network" {
  source = "./network"

  network_name            = lookup(var.config.network, "name", "coinops-network")
  subnetwork_name         = lookup(var.config.network, "subnet_name", "coinops-subnet")
  subnetwork_cidr         = lookup(var.config.network, "cidr", "10.10.0.0/16")
  auto_create_subnetworks = lookup(var.config.network, "gcp_auto_create_subnetworks", false)
  region = lookup(var.config.region_map, "gcp", "europe-central2")
}



module "firewall" {
  source   = "./firewall"

  name          = "${lookup(var.config, "name_prefix", "coinops")}-allow-ssh"
  network_id    = module.network.network_id
  direction     = "INGRESS"
  source_ranges = lookup(var.config.firewall, "ssh_source_ranges", ["0.0.0.0/0"])
  source_tags   = []
  target_tags   = lookup(var.config.instances.bastion, "tags", ["bastion"])
  protocol      = lookup(var.config.ssh, "protocol", "tcp")
  # convert to string
  ports = [tostring(lookup(var.config.ssh, "port", 22))]
}

module "private_ssh" {
  source = "./firewall"
  name          = "${lookup(var.config, "name_prefix", "coinops")}-private-ssh"
  network_id    = module.network.network_id
  direction     = "INGRESS"
  source_ranges = []
  source_tags   = lookup(var.config.instances.bastion, "tags", ["bastion"])
  target_tags   = ["k3s-node"]
  protocol      = lookup(var.config.ssh, "protocol", "tcp")
  ports         = [tostring(lookup(var.config.ssh, "port", 22))]
}


# to control cluster management traffic
module "k3s_internal" {
  source = "./firewall"
  name = "${lookup(var.config, "name_prefix", "coinops")}-k3s-internal"
  network_id = module.network.network_id
  direction = "INGRESS"
  source_ranges = [lookup(var.config.network, "private_subnetwork_cidr", "10.10.1.0/24")]
  source_tags = []
  target_tags = ["k3s-node"]
  protocol = "tcp"
  # 6443 - k3s API Server
  # 10250 - Kubelet API - server node talks to it for live operations with worker node
  # 2379, 2380 - etc - database that stores all cluster state
  ports = ["6443", "10250", "2379", "2380"]

}

# pod-to-pod traffic between nodes
# A pod is one running instance of your app in Kubernetes. It wraps one container (sometimes a few), has its own IP, and is disposable kill or spin up a new one anytime
module "k3s_flannel" {
  source        = "./firewall"
  name          = "${lookup(var.config, "name_prefix", "coinops")}-k3s-flannel"
  network_id    = module.network.network_id
  direction     = "INGRESS"
  source_ranges = [lookup(var.config.network, "private_subnetwork_cidr", "10.10.1.0/24")]
  source_tags   = []
  target_tags   = ["k3s-node"]
  protocol      = "udp"
  ports         = ["8472", "51820"]
}

# allow public internet to reach k3s-node-1 on HTTP/HTTPS (Traefik)
module "k3s_public_ingress" {
  source        = "./firewall"
  name          = "${lookup(var.config, "name_prefix", "coinops")}-k3s-public-ingress"
  network_id    = module.network.network_id
  direction     = "INGRESS"
  source_ranges = ["0.0.0.0/0"]
  source_tags   = []
  target_tags   = ["k3s-node"]
  protocol      = "tcp"
  ports         = ["80", "443"]
}

# allow bastion (Tailscale subnet router) to reach k3s on HTTP/HTTPS
module "k3s_from_bastion" {
  source        = "./firewall"
  name          = "${lookup(var.config, "name_prefix", "coinops")}-k3s-from-bastion"
  network_id    = module.network.network_id
  direction     = "INGRESS"
  source_ranges = []
  source_tags   = lookup(var.config.instances.bastion, "tags", ["bastion"])
  target_tags   = ["k3s-node"]
  protocol      = "tcp"
  ports         = ["80", "443"]
}

resource "cloudflare_record" "homepage" {
  zone_id = var.cloudflare_zone_id
  name = "home" # home.coin-ops.pp.ua
  type = "A"  # A - IPv4 (k3s-node-1 public ip)
  content = module.vm["k3s-node-1"].public_ip # its what the DNS record points to when browser asks for ip (provides ip of node-1)
  ttl = 60
  proxied = false
}

resource "cloudflare_record" "headlamp" {
  zone_id = var.cloudflare_zone_id
  name    = "headlamp"
  type    = "A"
  content = module.vm["k3s-node-1"].private_ip
  ttl     = 60
  proxied = false
}

module "vm" {
  source   = "./vm"
  # if instances if empty - no vm to this cloud is created
  for_each = var.instances
  
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
