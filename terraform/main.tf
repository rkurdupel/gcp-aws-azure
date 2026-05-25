# Create AWS infrastructure only when config cloud is "aws".
module "aws" {
  count = length(local.aws_instances) > 0 ? 1 : 0 # create module if it has instances
  source = "./modules/aws"

  config             = local.config
  ssh_public_key     = local.ssh_public_key
  cloudflare_zone_id = var.cloudflare_zone_id

  db_name     = var.db_name
  db_user     = var.db_user
  db_password = var.db_password

  domain_name = var.domain_name
  instances = local.aws_instances

}

module "gcp" {
  count = length(local.gcp_instances) > 0 ? 1 : 0
  source = "./modules/gcp"

  config         = local.config
  ssh_public_key = local.ssh_public_key
  instances = local.gcp_instances
  cloudflare_zone_id = var.cloudflare_zone_id
}

module "azure" {
  count = length(local.azure_instances) > 0 ? 1 : 0
  source = "./modules/azure"

  config         = local.config
  ssh_public_key = local.ssh_public_key
  instances = local.azure_instances
}