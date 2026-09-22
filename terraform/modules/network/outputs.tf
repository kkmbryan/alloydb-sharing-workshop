output "network_name" {
  description = "Name of the VPC."
  value       = local.network_name
}

output "network_self_link" {
  description = "Self link / id of the VPC. Pass this to the alloydb-cluster module as network_self_link."
  value       = local.network_self_link
}

output "subnet_self_link" {
  description = "Self link of the application subnet. Place PSC endpoints and client workloads here."
  value       = google_compute_subnetwork.app.id
}

output "subnet_cidr" {
  description = "CIDR of the application subnet."
  value       = google_compute_subnetwork.app.ip_cidr_range
}

output "psa_range_name" {
  description = <<-EOT
    Name of the reserved PSA range. Pass this to the alloydb-cluster module as
    allocated_ip_range. Null when PSA is disabled.
  EOT
  value       = var.enable_psa ? google_compute_global_address.psa_range[0].name : null
}

output "psa_connection_id" {
  description = <<-EOT
    ID of the service networking connection.

    Depend on this from the AlloyDB cluster: the peering must exist before the
    cluster can be created, and Terraform cannot infer that ordering on its own.
  EOT
  value       = var.enable_psa ? google_service_networking_connection.psa[0].id : null
}
