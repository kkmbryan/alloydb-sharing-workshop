output "cluster_name" {
  description = "Full cluster resource name."
  value       = module.alloydb.cluster_name
}

output "primary_ip_address" {
  description = "Private IP of the primary. Send all writes here."
  value       = module.alloydb.primary_ip_address
}

output "read_pool_ip_addresses" {
  description = <<-EOT
    Map of read pool instance_id to private IP.

    Each read pool instance has ONE stable endpoint that load balances across
    its nodes, so adding nodes does not change the connection string.
  EOT
  value       = module.alloydb.read_pool_ip_addresses
}

output "read_pool_nodes_used" {
  description = "Read pool nodes consumed, out of the 20 per-cluster budget."
  value       = "${module.alloydb.read_pool_total_nodes} / 20"
}

output "vcpu_quota_consumed" {
  description = "Total vCPUs consumed: REGIONAL primary counts twice, plus one VM per read pool node."
  value       = module.alloydb.estimated_vcpu_quota_consumed
}

output "routing_guidance" {
  description = "How the application should route traffic across these endpoints."
  value       = <<-EOT

    Writes and read-your-own-writes  -> primary (${module.alloydb.primary_ip_address})
    Application reads                -> app read pool
    Reports, BI, exports             -> analytics read pool

    Read pools are asynchronous. A read issued immediately after a write may
    not see it. Route any read that must observe a just-completed write to the
    primary, or carry the value forward in the application rather than
    re-reading it.

    Watch alloydb.googleapis.com/instance/postgres/replication/maximum_lag to
    quantify the staleness you are actually exposed to.
  EOT
}
