output "vm_ips" {
  value = {
    for name, vm in module.vm : name => {
      private_ip = vm.private_ip
      public_ip  = vm.public_ip
    }
  }
}
