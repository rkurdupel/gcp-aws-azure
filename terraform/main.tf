# Create AWS infrastructure only when config cloud is "aws".
module "aws" {
  # if cloud = aws - count = 1 ( create module once )
  count  = local.cloud == "aws" ? 1 : 0
  source = "./modules/aws"

  config         = local.config
  ssh_public_key = local.ssh_public_key

}

module "gcp" {
  count  = local.cloud == "gcp" ? 1 : 0
  source = "./modules/gcp"

  config         = local.config
  ssh_public_key = local.ssh_public_key
}