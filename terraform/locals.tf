locals {
  config         = yamldecode(trimspace(file("${path.root}/../config/config.yml")))
  cloud          = local.config.cloud
  ssh_public_key = trimspace(file(local.config.ssh.public_key_path))
}

