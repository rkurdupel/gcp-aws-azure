

resource "google_compute_network" "this" {
  name                    = var.network_name
  auto_create_subnetworks = var.auto_create_subnetworks
}

resource "google_compute_subnetwork" "this" {
  network       = google_compute_network.this.id # connect to object, not name
  name          = var.subnetwork_name
  ip_cidr_range = var.subnetwork_cidr

}

# Cloud Router — required for Cloud NAT
resource "google_compute_router" "this" {
  name    = "${var.network_name}-router"
  network = google_compute_network.this.id
  region  = var.region
}

# Cloud NAT — lets private VMs reach internet (apt update, docker pull)
resource "google_compute_router_nat" "this" {
  name                               = "${var.network_name}-nat"
  router                             = google_compute_router.this.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}