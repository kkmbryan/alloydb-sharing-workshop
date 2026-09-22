output "ip_address" {
  description = "Internal IP of the PSC endpoint. This is what clients connect to."
  value       = google_compute_address.psc.address
}

output "self_link" {
  description = "Self link of the reserved address."
  value       = google_compute_address.psc.self_link
}

output "forwarding_rule_id" {
  description = "ID of the forwarding rule that is the PSC endpoint."
  value       = google_compute_forwarding_rule.psc.id
}

output "dns_name" {
  description = <<-EOT
    The AlloyDB-advertised hostname, passed straight through.

    Null when the cluster is not on the PSC path. When create_dns is false,
    use this together with ip_address to create the A record in whichever
    system manages your DNS.
  EOT
  value       = var.dns_name
}

output "dns_created" {
  description = "Whether this module created the private zone and record."
  value       = var.create_dns && var.dns_name != null
}

output "connect_summary" {
  description = "How to reach the instance through this endpoint."
  value       = <<-EOT
    PSC endpoint
    ============
      region       : ${var.region}
      endpoint IP  : ${google_compute_address.psc.address}
      DNS name     : ${coalesce(var.dns_name, "(cluster is not on the PSC path)")}
      DNS record   : ${var.create_dns && var.dns_name != null ? "created by this module" : "NOT created - you must create it yourself"}

    Direct connection:
      psql "postgresql://USER@${google_compute_address.psc.address}:5432/postgres"

    Through Managed Connection Pooling, if enabled on the instance:
      psql "postgresql://USER@${google_compute_address.psc.address}:6432/postgres"

    Through the Auth Proxy, which needs the --psc flag and working DNS:
      ./alloydb-auth-proxy --psc \
        projects/${var.project_id}/locations/${var.region}/clusters/CLUSTER/instances/INSTANCE

    Note that the Auth Proxy and the Language Connectors resolve the DNS name
    rather than the IP, so they will not work until the A record exists.
  EOT
}
