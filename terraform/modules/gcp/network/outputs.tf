# after creating subnet, expose link to the subnet to the outside  (root main.tf etc.)
output "subnetwork_self_link" {
  value = google_compute_subnetwork.this.self_link
}

output "network_id" {
  value = google_compute_network.this.id
}