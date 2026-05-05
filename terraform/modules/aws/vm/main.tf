resource "aws_instance" "this" {
  ami                         = var.ami
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id # Places the instance in this subnet, giving it a private ip
  associate_public_ip_address = var.public_ip # give public ip if public_ip = true
  vpc_security_group_ids      = var.security_group_id
  # launch ec2 vm with registered key pair
  key_name = var.key_name
  user_data_replace_on_change = true


  # it creates your SSH user, installs your key, gives sudo access, changes SSH from port 22 to 9922, and restarts SSH.
  user_data = <<-EOF
  #!/bin/bash
  useradd -m -s /bin/bash ${var.ssh_user} || true
  mkdir -p /home/${var.ssh_user}/.ssh
  echo "${var.ssh_public_key}" > /home/${var.ssh_user}/.ssh/authorized_keys
  chown -R ${var.ssh_user}:${var.ssh_user} /home/${var.ssh_user}/.ssh
  chmod 700 /home/${var.ssh_user}/.ssh
  chmod 600 /home/${var.ssh_user}/.ssh/authorized_keys
  echo "${var.ssh_user} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${var.ssh_user}
  chmod 440 /etc/sudoers.d/${var.ssh_user}
  EOF

  private_ip = var.private_ip

  tags = {
    Name = var.name
    Role = length(var.tags) > 0 ? var.tags[0] : var.name # if there are tags (> 0) set var.tags otherwise var.name
  }
}
