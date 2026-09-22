output "cluster_name" {
  description = "Full cluster resource name."
  value       = module.alloydb.cluster_name
}

output "primary_psc_endpoint_ip" {
  description = "PSC endpoint IP for the primary. Send all writes here."
  value       = module.psc_endpoint_primary.ip_address
}

output "read_pool_psc_endpoint_ips" {
  description = <<-EOT
    Map of read pool instance_id to its PSC endpoint IP.

    Each read pool instance has ONE endpoint that load balances across its
    nodes, so adding nodes does not change the connection string. Adding a
    POOL does: a new pool means a new service attachment, a new endpoint and a
    new DNS record.
  EOT
  value       = { for k, m in module.psc_endpoint_read_pool : k => m.ip_address }
}

output "psc_dns_records_required" {
  description = <<-EOT
    Every hostname that must resolve, and the address it must resolve to.

    If create_psc_dns is false, create these records wherever your DNS is
    managed. The Auth Proxy and the language connectors resolve the hostname
    rather than the IP, so nothing connects until they exist.
  EOT
  value = merge(
    { (coalesce(module.alloydb.psc_dns_name, "primary-pending")) = module.psc_endpoint_primary.ip_address },
    {
      for k, m in module.psc_endpoint_read_pool :
      coalesce(module.alloydb.read_pool_psc_dns_names[k], "${k}-pending") => m.ip_address
    }
  )
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

    Writes and read-your-own-writes  -> primary (${module.psc_endpoint_primary.ip_address})
    Application reads                -> app read pool endpoint
    Reports, BI, exports             -> analytics read pool endpoint

    Each of those is a separate PSC endpoint in your subnet. See the
    read_pool_psc_endpoint_ips output for the addresses.

    Read pools are asynchronous. A read issued immediately after a write may
    not see it. Route any read that must observe a just-completed write to the
    primary, or carry the value forward in the application rather than
    re-reading it.

    Watch alloydb.googleapis.com/instance/postgres/replication/maximum_lag to
    quantify the staleness you are actually exposed to.
  EOT
}
