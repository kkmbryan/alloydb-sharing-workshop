output "alert_policy_names" {
  description = "Resource names of all alert policies created, for cross-referencing in runbooks or incident tooling."
  value = var.enabled ? compact([
    try(google_monitoring_alert_policy.cpu_high[0].name, ""),
    try(google_monitoring_alert_policy.connections_high[0].name, ""),
    try(google_monitoring_alert_policy.memory_low[0].name, ""),
    try(google_monitoring_alert_policy.txid_wraparound[0].name, ""),
    try(google_monitoring_alert_policy.storage_quota[0].name, ""),
    try(google_monitoring_alert_policy.replication_lag[0].name, ""),
    try(google_monitoring_alert_policy.node_down[0].name, ""),
    try(google_monitoring_alert_policy.backup_stale[0].name, ""),
    try(google_monitoring_alert_policy.audit_backlog[0].name, ""),
  ]) : []
}

output "dashboard_id" {
  description = "Resource name of the Cloud Monitoring dashboard."
  value       = try(google_monitoring_dashboard.alloydb[0].id, null)
}

output "alert_count" {
  description = "Number of alert policies created."
  value       = var.enabled ? (8 + (var.enable_audit_backlog_alert ? 1 : 0)) : 0
}
