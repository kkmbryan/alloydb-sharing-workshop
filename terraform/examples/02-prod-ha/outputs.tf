output "cluster_name" {
  description = "Full cluster resource name."
  value       = module.alloydb.cluster_name
}

output "primary_instance_name" {
  description = "Full primary instance resource name. This is the Auth Proxy instance URI."
  value       = module.alloydb.primary_instance_name
}

output "primary_ip_address" {
  description = "Private IP of the primary instance."
  value       = module.alloydb.primary_ip_address
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

    Direct (bypasses the pooler):      port 5432
    Managed Connection Pooling:        port 6432   <- use this from the app

    Via the Auth Proxy:
      ./alloydb-auth-proxy ${module.alloydb.primary_instance_name}
      psql -h 127.0.0.1 -U postgres -d postgres

    With IAM database authentication (no password):
      ./alloydb-auth-proxy --auto-iam-authn ${module.alloydb.primary_instance_name}

    Reminder: the pooler runs in transaction mode. Session-scoped state,
    session advisory locks, LISTEN/NOTIFY, WITH HOLD cursors and temp tables
    will not behave as they do on a direct connection. Run schema migrations
    against port 5432.
  EOT
}
