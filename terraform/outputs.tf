output "vm_ips" {
  value = local.cloud == "aws" ? module.aws[0].vm_ips : module.gcp[0].vm_ips
}

# if aws - from aws module first instance 
output "bastion_public_ip" {
  value = local.cloud == "aws" ? module.aws[0].vm_ips["bastion"].public_ip : module.gcp[0].vm_ips["bastion"].public_ip
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
  )) : join("\n", concat(
    ["[bastion]"],
    [for name, vm in module.gcp[0].vm_ips :
      "coinops-${name} ansible_host=${vm.public_ip} ansible_user=${local.config.ssh.user}"
      if vm.public_ip != null
    ],
    ["", "[db]"],
    [for name, vm in module.gcp[0].vm_ips :
      "coinops-${name} ansible_host=${vm.private_ip} ansible_user=${local.config.ssh.user} ansible_ssh_common_args='-o StrictHostKeyChecking=no -o ProxyJump=${local.config.ssh.user}@${module.gcp[0].vm_ips["bastion"].public_ip}'"
      if startswith(name, "db")
    ],
    ["", "[app]"],
    [for name, vm in module.gcp[0].vm_ips :
      "coinops-${name} ansible_host=${vm.private_ip} ansible_user=${local.config.ssh.user} ansible_ssh_common_args='-o StrictHostKeyChecking=no -o ProxyJump=${local.config.ssh.user}@${module.gcp[0].vm_ips["bastion"].public_ip}'"
      if startswith(name, "app")
    ],
    ["", "[cloud:children]", "bastion", "db", "app"]
  ))
}


output "ssh_config" {
  value = join("\n", concat(
    [
      "Host coinops-bastion",
      "  HostName ${local.cloud == "aws" ? module.aws[0].vm_ips["bastion"].public_ip : module.gcp[0].vm_ips["bastion"].public_ip}",
      "  User ${local.config.ssh.user}",
      "  IdentityFile ~/.ssh/id_ed25519",
      "  StrictHostKeyChecking accept-new",
      ""
    ],
    [for name, vm in (local.cloud == "aws" ? module.aws[0].vm_ips : module.gcp[0].vm_ips) :
      join("\n", [
        "Host coinops-${name}",
        "  HostName ${vm.private_ip}",
        "  User ${local.config.ssh.user}",
        "  IdentityFile ~/.ssh/id_ed25519",
        "  ProxyJump coinops-bastion",
        "  StrictHostKeyChecking accept-new",
        ""
      ])
      if name != "bastion"
    ]
  ))
}


output "alb_dns_name" {
  value = local.cloud == "aws" ? module.aws[0].alb_dns_name : null
}

output "rds_endpoint" {
  value = local.cloud == "aws" ? module.aws[0].rds_endpoint : null
}