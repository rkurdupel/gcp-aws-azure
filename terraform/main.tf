# Create AWS infrastructure only when config cloud is "aws".
module "aws" {
  # if cloud = aws - count = 1 ( create module once )
  count  = local.cloud == "aws" ? 1 : 0
  source = "./modules/aws"

  config         = local.config
  ssh_public_key = local.ssh_public_key
  cloudflare_zone_id = var.cloudflare_zone_id

  db_name = var.db_name
  db_user = var.db_user
  db_password = var.db_password

  domain_name = var.domain_name

}

module "gcp" {
  count  = local.cloud == "gcp" ? 1 : 0
  source = "./modules/gcp"

  config         = local.config
  ssh_public_key = local.ssh_public_key
}
