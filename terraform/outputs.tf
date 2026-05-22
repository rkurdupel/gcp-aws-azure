# locals - not to use merge in every output
# merging dat about vm generated on each cloud
locals {
  vm_ips = merge(
    length(local.aws_instances) > 0 ? module.aws[0].vm_ips : {},
    length(local.gcp_instances) > 0 ? module.gcp[0].vm_ips : {},
    length(local.azure_instances) > 0 ? module.azure[0].vm_ips : {} # if azure instances exist return their info else {}
  )
}

output "vm_ips" {
  value = local.vm_ips
}

# if aws - from aws module first instance 
output "bastion_public_ip" {
  value = local.vm_ips["bastion"].public_ip
}

output "ansible_inventory" {
  value = join("\n", concat(
    ["[bastion]"],
    [for name, vm in local.vm_ips :
      "coinops-${name} ansible_host=${vm.public_ip} ansible_user=${local.config.ssh.user}"
      if vm.public_ip != null
    ],
    ["", "[k3s_server]"],
    [for name, vm in local.vm_ips :
      "coinops-${name} ansible_host=${vm.private_ip} ansible_user=${local.config.ssh.user} ansible_ssh_common_args='-o StrictHostKeyChecking=no -o ProxyJump=${local.config.ssh.user}@${local.vm_ips["bastion"].public_ip}'"
      if startswith(name, "k3s-server")
    ],
    ["", "[k3s_worker]"],
    [for name, vm in local.vm_ips :
      "coinops-${name} ansible_host=${vm.private_ip} ansible_user=${local.config.ssh.user} ansible_ssh_common_args='-o StrictHostKeyChecking=no -o ProxyJump=${local.config.ssh.user}@${local.vm_ips["bastion"].public_ip}'"
      if startswith(name, "k3s-worker")
    ],
    ["", "[cloud:children]", "bastion", "k3s_server", "k3s_worker"]
  ))
}

output "ssh_config" {
  value = join("\n", concat(
    [
      "Host coinops-bastion",
      "  HostName ${local.vm_ips["bastion"].public_ip}",
      "  User ${local.config.ssh.user}",
      "  IdentityFile ~/.ssh/id_ed25519",
      "  StrictHostKeyChecking accept-new",
      ""
    ],
    [for name, vm in local.vm_ips :
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
  value = length(local.aws_instances) > 0 ? module.aws[0].alb_dns_name : null
}

output "rds_endpoint" {
  value = length(local.aws_instances) > 0 ? module.aws[0].rds_endpoint : null
}