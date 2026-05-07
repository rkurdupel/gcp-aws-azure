output "vm_ips" {
  value = local.cloud == "aws" ? module.aws[0].vm_ips : module.gcp[0].vm_ips
}

# if aws - from aws module first instance 
output "bastion_public_ip" {
  value = local.cloud == "aws" ? module.aws[0].vm_ips["bastion"].public_ip : null
}

output "ansible_inventory" {
  value = local.cloud == "aws" ? join("\n", concat(
    ["[bastion]"],
    [for name, vm in module.aws[0].vm_ips : 
      "coinops-${name} ansible_host=${vm.public_ip} ansible_user=${local.config.ssh.user}"
      if vm.public_ip != ""
    ],
    ["", "[db]"],
    [for name, vm in module.aws[0].vm_ips :
      "coinops-${name} ansible_host=${vm.private_ip} ansible_user=${local.config.ssh.user} ansible_ssh_common_args='-o StrictHostKeyChecking=no -o ProxyJump=${local.config.ssh.user}@${module.aws[0].vm_ips["bastion"].public_ip}'"
      if startswith(name, "db")
    ],
    ["", "[app]"],
    [for name, vm in module.aws[0].vm_ips :
      "coinops-${name} ansible_host=${vm.private_ip} ansible_user=${local.config.ssh.user} ansible_ssh_common_args='-o StrictHostKeyChecking=no -o ProxyJump=${local.config.ssh.user}@${module.aws[0].vm_ips["bastion"].public_ip}'"
      if startswith(name, "app")
    ],
    ["", "[cloud:children]", "bastion", "db", "app"]
  )) : ""
}


output "ssh_config" {
  value = local.cloud == "aws" ? join("\n", [
    "Host coinops-bastion",
    "  HostName ${module.aws[0].vm_ips["bastion"].public_ip}",
    "  User ${local.config.ssh.user}",
    "  IdentityFile ~/.ssh/id_ed25519",
    "  StrictHostKeyChecking accept-new",
    "",
    "Host coinops-db",
    "  HostName ${module.aws[0].vm_ips["db"].private_ip}",
    "  User ${local.config.ssh.user}",
    "  IdentityFile ~/.ssh/id_ed25519",
    "  ProxyJump coinops-bastion",
    "  StrictHostKeyChecking accept-new",
    "",
    "Host coinops-app-1",
    "  HostName ${module.aws[0].vm_ips["app-1"].private_ip}",
    "  User ${local.config.ssh.user}",
    "  IdentityFile ~/.ssh/id_ed25519",
    "  ProxyJump coinops-bastion",
    "  StrictHostKeyChecking accept-new",
    "",
    "Host coinops-app-2",
    "  HostName ${module.aws[0].vm_ips["app-2"].private_ip}",
    "  User ${local.config.ssh.user}",
    "  IdentityFile ~/.ssh/id_ed25519",
    "  ProxyJump coinops-bastion",
    "  StrictHostKeyChecking accept-new"
  ]) : ""
}


output "alb_dns_name" {
  value = local.cloud == "aws" ? module.aws[0].alb_dns_name : null
}