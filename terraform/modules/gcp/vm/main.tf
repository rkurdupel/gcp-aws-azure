resource "google_compute_instance" "this" {
  name         = var.name
  zone         = var.zone
  machine_type = var.machine_type
  tags         = var.tags

  boot_disk {
    initialize_params {
      image = var.boot_image
      size  = var.size_gb
    }
  }

  network_interface {
    # give internal ip to vm
    subnetwork = var.subnetwork_self_link

    network_ip = null # tell gcp to assign an internal ip from the subnet

    # if public ip = true - create access_config else do not
    # dynamic to handle presence of public_ip = != true
    dynamic "access_config" {
      for_each = var.public_ip ? [1] : []
      content {}
    }
  }

  metadata = {
    ssh-keys = "${var.ssh_user}:${var.ssh_public_key}"
  }

  # configure 9922 port
  metadata_startup_script = <<-EOF
  #!/bin/bash
  sed -i 's/^#\\?Port .*/Port ${var.ssh_port}/' /etc/ssh/sshd_config
  grep -q '^Port ${var.ssh_port}$' /etc/ssh/sshd_config || echo 'Port ${var.ssh_port}' >> /etc/ssh/sshd_config
  systemctl restart ssh || systemctl restart sshd
  EOF


}
