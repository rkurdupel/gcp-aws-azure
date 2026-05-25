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

    network_ip = var.private_ip

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
}
