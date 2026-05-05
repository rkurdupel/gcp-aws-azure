

resource "google_compute_network" "this" {
  name                    = var.network_name
  auto_create_subnetworks = var.auto_create_subnetworks
}

resource "google_compute_subnetwork" "this" {
  network       = google_compute_network.this.id # connect to object, not name
  name          = var.subnetwork_name
  ip_cidr_range = var.subnetwork_cidr

}