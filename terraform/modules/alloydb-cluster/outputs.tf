output "cluster_id" {
  description = "Short cluster ID."
  value       = google_alloydb_cluster.this.cluster_id
}

output "cluster_name" {
  description = "Full resource name: projects/P/locations/L/clusters/C. Use this wherever another resource asks for a cluster."
  value       = google_alloydb_cluster.this.name
}

output "primary_instance_name" {
  description = "Full resource name of the primary instance."
  value       = google_alloydb_instance.primary.name
}

output "primary_instance_id" {
  description = "Short instance ID of the primary. Useful as a Cloud Monitoring resource.labels.instance_id filter value."
  value       = google_alloydb_instance.primary.instance_id
}

output "primary_ip_address" {
  description = <<-EOT
    Private IP of the primary instance. This is what you put in a connection
    string on the PSA path. Empty on the PSC path - there you connect to your
    own PSC endpoint IP instead.
  EOT
  value       = google_alloydb_instance.primary.ip_address
}

output "primary_uri" {
  description = <<-EOT
    Instance URI for the AlloyDB Auth Proxy:
      alloydb-auth-proxy <this value>
  EOT
  value       = google_alloydb_instance.primary.name
}

output "psc_service_attachment_link" {
  description = <<-EOT
    PSC path only. Target for the consumer-side google_compute_forwarding_rule.
    Null when the cluster uses PSA.
  EOT
  value = try(
    google_alloydb_instance.primary.psc_instance_config[0].service_attachment_link,
    null
  )
}

output "psc_dns_name" {
  description = <<-EOT
    PSC path only. The DNS name AlloyDB recommends you map to your PSC endpoint
    IP in a private Cloud DNS zone. Note it includes a trailing dot.
  EOT
  value = try(
    google_alloydb_instance.primary.psc_instance_config[0].psc_dns_name,
    null
  )
}

output "read_pool_instance_names" {
  description = "Map of read pool instance_id to full resource name."
  value       = { for k, v in google_alloydb_instance.read_pool : k => v.name }
}

output "read_pool_ip_addresses" {
  description = <<-EOT
    Map of read pool instance_id to private IP. Point read-only traffic here.

    Empty strings on the PSC path: a PSC instance has no IP inside your VPC.
    Use read_pool_psc_service_attachment_links instead.
  EOT
  value       = { for k, v in google_alloydb_instance.read_pool : k => v.ip_address }
}

output "read_pool_psc_service_attachment_links" {
  description = <<-EOT
    PSC path only. Map of read pool instance_id to its service attachment.

    Each read pool publishes its OWN attachment, so each one needs its own
    consumer endpoint. Nothing routes read traffic for you - see
    terraform/examples/03-read-pool-scaling.
  EOT
  value = {
    for k, v in google_alloydb_instance.read_pool :
    k => try(v.psc_instance_config[0].service_attachment_link, null)
  }
}

output "read_pool_psc_dns_names" {
  description = <<-EOT
    PSC path only. Map of read pool instance_id to the hostname AlloyDB
    advertises for it. Each must resolve to that pool's endpoint IP.
  EOT
  value = {
    for k, v in google_alloydb_instance.read_pool :
    k => try(v.psc_instance_config[0].psc_dns_name, null)
  }
}

output "read_pool_total_nodes" {
  description = <<-EOT
    Total read pool nodes in this cluster. The per-cluster budget is 20 nodes
    summed across all read pool instances.
  EOT
  value       = sum(concat([0], [for v in var.read_pool_instances : v.node_count]))
}

output "estimated_vcpu_quota_consumed" {
  description = <<-EOT
    Approximate vCPUs consumed against the per-project-per-region quota.

    A REGIONAL primary runs two VMs (active + standby), so it costs 2x its
    vCPU count. Each read pool node costs one VM. Compare this against your
    VCPUsUsedPerProjectPerRegion quota before applying.
  EOT
  value = (
    var.cpu_count * (var.availability_type == "REGIONAL" ? 2 : 1)
    ) + sum(concat([0], [
      for v in var.read_pool_instances : v.node_count * coalesce(v.cpu_count, var.cpu_count)
  ]))
}
