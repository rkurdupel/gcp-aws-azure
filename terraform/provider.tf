provider "aws" {
  region = local.config.region_map.aws
}

provider "google" {
  project = local.config.clouds.gcp.project_id
  region  = local.config.region_map.gcp
}


provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
