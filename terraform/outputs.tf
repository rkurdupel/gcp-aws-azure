output "vm_ips" {
  value = local.cloud == "aws" ? module.aws[0].vm_ips : module.gcp[0].vm_ips
}