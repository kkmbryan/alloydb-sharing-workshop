variable "project_id" {
  description = "Project containing the AlloyDB cluster and where alert policies are created."
  type        = string
}

variable "cluster_id" {
  description = "AlloyDB cluster ID to monitor. Used as a resource.labels.cluster_id filter."
  type        = string
}

variable "notification_channel_ids" {
  description = <<-EOT
    Cloud Monitoring notification channel resource names, e.g.
    projects/P/notificationChannels/12345.

    Leave empty to create the policies without notifications - they still
    show up in the console, which is useful for a workshop, but nobody gets
    paged.
  EOT
  type        = list(string)
  default     = []
}

variable "alert_name_prefix" {
  description = "Prefix for alert policy display names, so policies from several clusters stay distinguishable."
  type        = string
  default     = "AlloyDB"
}

variable "enabled" {
  description = "Master switch. Set false to create the module without any policies."
  type        = bool
  default     = true
}

# ===========================================================================
# Thresholds
#
# IMPORTANT: Google does NOT publish official numeric alerting thresholds for
# AlloyDB. Every default below is a considered starting point, not a vendor
# recommendation. Calibrate against two weeks of your own baseline before you
# let any of these page a human.
#
# SCALE WARNING: metrics with unit 10^2.% and the transaction ID metric return
# a FRACTION between 0 and 1 from the API, even though the console renders a
# percentage and some metric descriptions say "0 to 100". Verified empirically
# against a live instance. So 0.85 means 85%.
# ===========================================================================

variable "cpu_threshold" {
  description = "Fraction (0-1) of CPU utilisation that triggers a warning. 0.85 = 85%."
  type        = number
  default     = 0.85
}

variable "cpu_duration" {
  description = "How long CPU must stay above the threshold. Long enough to ignore normal spikes and autovacuum."
  type        = string
  default     = "300s"
}

variable "connection_utilization_threshold" {
  description = <<-EOT
    Fraction of max_connections in use.

    Expressed as a RATIO of total_connections to connections_limit, so the
    alert keeps working after you resize the instance or change
    max_connections. A hardcoded connection count silently rots.
  EOT
  type        = number
  default     = 0.8
}

variable "memory_available_bytes_threshold" {
  description = <<-EOT
    Alert when the minimum available memory across serving nodes falls below
    this many bytes.

    There is no ratio metric for memory, so this is an absolute value and MUST
    be set relative to the instance's RAM. Default 2 GiB suits a small
    instance; raise it proportionally for larger shapes.
  EOT
  type        = number
  default     = 2147483648
}

variable "replication_lag_ms_threshold" {
  description = "Read pool replication lag in milliseconds. Set from your application's staleness tolerance."
  type        = number
  default     = 30000
}

variable "storage_quota_threshold" {
  description = <<-EOT
    Fraction of the per-cluster storage QUOTA consumed.

    AlloyDB storage is elastic, so this is not a disk-full alert - it is a
    quota-exhaustion alert. Hitting the quota fails writes. The default quota
    is 16 TiB per cluster, raisable to 128 TiB, so give yourself lead time.
  EOT
  type        = number
  default     = 0.8
}

variable "txid_utilization_warning" {
  description = <<-EOT
    Fraction (0-1) of the 2-billion transaction ID space consumed.

    This is the most dangerous slow-burn failure in PostgreSQL: exhaust the
    XID space and the database stops accepting writes.

    The metric returns a FRACTION, not a percentage, despite its description
    saying "percentage". This was confirmed by sampling three independent
    live clusters, which read 0.0895, 0.0699 and 0.0723. Under the fraction
    reading those correspond to 179M, 140M and 145M transactions - all just
    below the 200M default autovacuum_freeze_max_age, which is exactly where
    healthy PostgreSQL steady state sits. A threshold of 85 rather than 0.85
    would silently never fire.

    Why 0.2 and not something larger: because autovacuum freezes at 200M
    transactions, a healthy instance never exceeds about 0.10. A threshold of
    0.2 therefore means "XID age is twice what autovacuum should ever allow",
    which is a real signal that vacuum is losing ground. Thresholds up near
    0.8 only fire once you are close to a write outage, which is far too late
    to be useful.
  EOT
  type        = number
  default     = 0.2
}

variable "txid_utilization_critical" {
  description = <<-EOT
    Fraction (0-1) of XID space consumed that warrants paging someone.

    0.4 is four times the level autovacuum should permit. Reaching it means
    vacuum has been blocked for a sustained period - typically by a long-running
    transaction, an orphaned prepared transaction, or an orphaned replication
    slot. See docs/04-operations/troubleshooting-runbook.md.
  EOT
  type        = number
  default     = 0.4
}


variable "backup_max_age_hours" {
  description = <<-EOT
    Alert if the newest backup is older than this.

    Silent backup failure is the classic disaster: nobody notices until a
    restore is needed. Set slightly above your backup interval.
  EOT
  type        = number
  default     = 48
}

variable "enable_audit_backlog_alert" {
  description = <<-EOT
    Alert when the pgAudit shipping pipeline falls behind.

    A lagging audit pipeline means audit records are buffered and may be lost -
    a compliance failure that is otherwise invisible. Enable when pgAudit is on.
  EOT
  type        = bool
  default     = false
}

variable "audit_backlog_bytes_threshold" {
  description = "Audit backlog in bytes that indicates the pipeline is not keeping up."
  type        = number
  default     = 104857600
}

variable "create_dashboard" {
  description = "Create the bundled Cloud Monitoring dashboard."
  type        = bool
  default     = true
}
