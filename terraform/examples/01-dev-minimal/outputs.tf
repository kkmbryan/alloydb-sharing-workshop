output "cluster_name" {
  description = "Full cluster resource name."
  value       = module.alloydb.cluster_name
}

output "primary_ip_address" {
  description = "Private IP of the primary instance."
  value       = module.alloydb.primary_ip_address
}

output "vcpu_quota_consumed" {
  description = "vCPUs consumed against the per-project-per-region quota."
  value       = module.alloydb.estimated_vcpu_quota_consumed
}

output "connect_via_auth_proxy" {
  description = "Copy-paste commands to connect."
  value       = <<-EOT

    1. Start the AlloyDB Auth Proxy (requires roles/alloydb.client):

       ./alloydb-auth-proxy ${module.alloydb.primary_instance_name}

    2. In another terminal:

       psql -h 127.0.0.1 -p 5432 -U postgres -d postgres

    The proxy must run somewhere with network reachability to the instance -
    a VM in this VPC, or your workstation over VPN/Interconnect. It is not a
    substitute for connectivity.
  EOT
}
