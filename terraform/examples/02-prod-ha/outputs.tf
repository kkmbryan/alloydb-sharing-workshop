output "cluster_name" {
  description = "Full cluster resource name."
  value       = module.alloydb.cluster_name
}

output "primary_instance_name" {
  description = "Full primary instance resource name. This is the Auth Proxy instance URI."
  value       = module.alloydb.primary_instance_name
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
  description = "Service attachment the endpoint targets. Needed to add endpoints in other projects."
  value       = module.alloydb.psc_service_attachment_link
}

output "psc_endpoint_summary" {
  description = "Endpoint details and the connection commands that go with them."
  value       = module.psc_endpoint.connect_summary
}

output "vcpu_quota_consumed" {
  description = <<-EOT
    vCPUs consumed against VCPUsUsedPerProjectPerRegion.
    A REGIONAL primary counts twice: active plus standby.
  EOT
  value       = module.alloydb.estimated_vcpu_quota_consumed
}

output "alert_policies" {
  description = "Alert policies created for this cluster."
  value       = module.observability.alert_policy_names
}

output "dashboard_id" {
  description = "Cloud Monitoring dashboard resource name."
  value       = module.observability.dashboard_id
}

output "connection_notes" {
  description = "How to connect, and which port does what."
  value       = <<-EOT

    Endpoint IP:                       ${module.psc_endpoint.ip_address}
    Direct (bypasses the pooler):      port 5432
    Managed Connection Pooling:        port 6432   <- use this from the app

    Before anything resolves, the PSC hostname needs an A record. If you set
    create_psc_dns = false, create it wherever your DNS is managed:

      ${coalesce(module.alloydb.psc_dns_name, "(pending apply)")}  A  ${module.psc_endpoint.ip_address}

    Via the Auth Proxy. The --psc flag tells it to use the PSC endpoint, and it
    resolves the hostname above rather than the IP:
      ./alloydb-auth-proxy --psc ${module.alloydb.primary_instance_name}
      psql -h 127.0.0.1 -U postgres -d postgres

    With IAM database authentication (no password):
      ./alloydb-auth-proxy --psc --auto-iam-authn ${module.alloydb.primary_instance_name}

    The Auth Proxy works with managed connection pooling without any change on
    your side: the service pools the proxy's connections separately, so
    applications behind the proxy keep pointing at the proxy's local port.

    Reminder: the pooler runs in transaction mode. Session-scoped state,
    session advisory locks, LISTEN/NOTIFY, WITH HOLD cursors and temp tables
    will not behave as they do on a direct connection. Run schema migrations
    against port 5432.
  EOT
}
