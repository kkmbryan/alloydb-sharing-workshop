output "cluster_name" {
  description = "Full cluster resource name."
  value       = module.alloydb.cluster_name
}

output "psc_endpoint_ip" {
  description = <<-EOT
    Internal IP of the PSC endpoint. This is the address clients connect to.

    On the PSC path the instance has no IP inside your VPC - the endpoint you
    created does.
  EOT
  value       = module.psc_endpoint.ip_address
}

output "psc_dns_name" {
  description = "Hostname AlloyDB advertises for this instance. Must resolve to psc_endpoint_ip."
  value       = module.alloydb.psc_dns_name
}

output "psc_service_attachment" {
  description = "Service attachment the endpoint targets. Useful when adding endpoints in other projects."
  value       = module.alloydb.psc_service_attachment_link
}

output "vcpu_quota_consumed" {
  description = "vCPUs consumed against the per-project-per-region quota."
  value       = module.alloydb.estimated_vcpu_quota_consumed
}

output "psc_endpoint_summary" {
  description = "Endpoint details and the connection commands that go with them."
  value       = module.psc_endpoint.connect_summary
}

output "connect_via_auth_proxy" {
  description = "Copy-paste commands to connect."
  value       = <<-EOT

    1. Make sure the PSC hostname resolves. If you set create_psc_dns = false,
       create this A record in whichever system manages your DNS:

         ${coalesce(module.alloydb.psc_dns_name, "(pending apply)")}  A  ${module.psc_endpoint.ip_address}

       The Auth Proxy resolves the hostname, not the IP, so it cannot connect
       until this record exists.

    2. Start the AlloyDB Auth Proxy (requires roles/alloydb.client). The --psc
       flag tells it to use the PSC endpoint rather than a PSA address:

       ./alloydb-auth-proxy --psc ${module.alloydb.primary_instance_name}

    3. In another terminal:

       psql -h 127.0.0.1 -p 5432 -U postgres -d postgres

    The proxy must run somewhere with network reachability to the endpoint - a
    VM in this VPC, or your workstation over VPN/Interconnect. It is not a
    substitute for connectivity.

    To connect without the proxy, point psql at the endpoint IP directly:

       psql "postgresql://postgres@${module.psc_endpoint.ip_address}:5432/postgres"

    Managed connection pooling is enabled on this instance, so port 6432 on the
    same endpoint reaches the pooler instead.
  EOT
}
