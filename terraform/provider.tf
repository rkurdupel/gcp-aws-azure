provider "aws" {
  region = local.config.region_map.aws
}

provider "google" {
  project = local.config.project.gcp_project_id
  region  = local.config.region_map.gcp
}

