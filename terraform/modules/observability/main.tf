# ===========================================================================
# AlloyDB alert policies
#
# Every metric type below was confirmed to exist by querying the Cloud
# Monitoring metricDescriptors API against a live AlloyDB instance on
# 2026-09-22. A misspelled metric type still passes `terraform validate` and
# then never fires, so this matters more than it looks.
#
# Two metric names people commonly get wrong:
#   * alloydb.googleapis.com/instance/cpu/utilization  DOES NOT EXIST.
#     Use average_utilization or maximum_utilization.
#   * the project resource label is `project_id`, not `resource_container`.
# ===========================================================================

locals {
  enabled = var.enabled ? 1 : 0

  # Common filter fragment. Scoping by cluster_id keeps one cluster's alerts
  # from firing on another's metrics in a shared project.
  cluster_filter = <<-EOT
    resource.type = "alloydb.googleapis.com/Instance" AND
    resource.labels.cluster_id = "${var.cluster_id}"
  EOT

  runbook = "See docs/04-operations/troubleshooting-runbook.md in the workshop repository."
}

# ---------------------------------------------------------------------------
# 1. CPU saturation
#
# maximum_utilization, not average: on a multi-node instance one saturated
# node is a real problem that an average across nodes will hide.
# ---------------------------------------------------------------------------
resource "google_monitoring_alert_policy" "cpu_high" {
  count = local.enabled

  project      = var.project_id
  display_name = "${var.alert_name_prefix} - CPU utilisation high (${var.cluster_id})"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "Max CPU across nodes above threshold"

    condition_threshold {
      filter = <<-EOT
        metric.type = "alloydb.googleapis.com/instance/cpu/maximum_utilization" AND
        ${local.cluster_filter}
      EOT

      # Fraction, not percent. 0.85 = 85%.
      comparison      = "COMPARISON_GT"
      threshold_value = var.cpu_threshold
      duration        = var.cpu_duration

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }

      evaluation_missing_data = "EVALUATION_MISSING_DATA_INACTIVE"
    }
  }

  notification_channels = var.notification_channel_ids

  alert_strategy {
    auto_close = "3600s"
  }

  documentation {
    mime_type = "text/markdown"
    subject   = "AlloyDB CPU high on ${var.cluster_id}"
    content   = <<-EOT
      CPU on the busiest node of `${var.cluster_id}` has been above
      ${var.cpu_threshold * 100}% for ${var.cpu_duration}.

      **Check the queries before resizing the instance.** Scaling hardware to
      compensate for a missing index is the most expensive possible fix.

      1. Query Insights, ordered by database load.
      2. `monitoring/sql/01_top_queries.sql` query A - top queries by TOTAL time.
      3. Only then consider raising `cpu_count`.

      ${local.runbook}
    EOT
  }
}

# ---------------------------------------------------------------------------
# 2. Connection saturation - as a RATIO
#
# total_connections / connections_limit. Because connections_limit is itself a
# metric, this alert stays correct after a resize or a max_connections change.
# ---------------------------------------------------------------------------
resource "google_monitoring_alert_policy" "connections_high" {
  count = local.enabled

  project      = var.project_id
  display_name = "${var.alert_name_prefix} - Connection utilisation high (${var.cluster_id})"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "Connections above fraction of max_connections"

    condition_threshold {
      filter = <<-EOT
        metric.type = "alloydb.googleapis.com/instance/postgres/total_connections" AND
        ${local.cluster_filter}
      EOT

      denominator_filter = <<-EOT
        metric.type = "alloydb.googleapis.com/instance/postgres/connections_limit" AND
        ${local.cluster_filter}
      EOT

      comparison      = "COMPARISON_GT"
      threshold_value = var.connection_utilization_threshold
      duration        = "300s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }

      denominator_aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }

      evaluation_missing_data = "EVALUATION_MISSING_DATA_INACTIVE"
    }
  }

  notification_channels = var.notification_channel_ids

  alert_strategy {
    auto_close = "3600s"
  }

  documentation {
    mime_type = "text/markdown"
    subject   = "AlloyDB connections high on ${var.cluster_id}"
    content   = <<-EOT
      Connection usage on `${var.cluster_id}` is above
      ${var.connection_utilization_threshold * 100}% of `max_connections`.

      Raising `max_connections` is almost always the wrong fix - it costs
      memory that would otherwise serve the shared buffer cache, and it
      requires a restart.

      1. `monitoring/sql/02_connections_and_locks.sql` query B - find which
         application is holding the connections.
      2. Query E - look for `idle in transaction` sessions, the usual culprit.
      3. Durable fix: connection pooling. See
         `config/connection-pooling/app-side-pool-sizing.md`.

      ${local.runbook}
    EOT
  }
}

# ---------------------------------------------------------------------------
# 3. Memory pressure
#
# Absolute bytes - there is no ratio metric for memory, so this threshold must
# be tuned per instance shape.
# ---------------------------------------------------------------------------
resource "google_monitoring_alert_policy" "memory_low" {
  count = local.enabled

  project      = var.project_id
  display_name = "${var.alert_name_prefix} - Available memory low (${var.cluster_id})"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "Minimum available memory below threshold"

    condition_threshold {
      filter = <<-EOT
        metric.type = "alloydb.googleapis.com/instance/memory/min_available_memory" AND
        ${local.cluster_filter}
      EOT

      comparison      = "COMPARISON_LT"
      threshold_value = var.memory_available_bytes_threshold
      duration        = "300s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MIN"
      }

      evaluation_missing_data = "EVALUATION_MISSING_DATA_INACTIVE"
    }
  }

  notification_channels = var.notification_channel_ids

  alert_strategy {
    auto_close = "3600s"
  }

  documentation {
    mime_type = "text/markdown"
    subject   = "AlloyDB memory low on ${var.cluster_id}"
    content   = <<-EOT
      Available memory on `${var.cluster_id}` is below the configured floor.

      Common causes, in order of likelihood:

      * `work_mem` set too high multiplied by too many concurrent connections.
        `work_mem` is per sort/hash operation per session, not per instance.
      * The columnar engine's memory budget competing with the row-store
        buffer cache.
      * Genuine undersizing for the working set.

      **This threshold is an absolute byte value and must be re-tuned whenever
      the instance is resized.**

      ${local.runbook}
    EOT
  }
}

# ---------------------------------------------------------------------------
# 4. Transaction ID wraparound - the one that actually takes you down
# ---------------------------------------------------------------------------
resource "google_monitoring_alert_policy" "txid_wraparound" {
  count = local.enabled

  project      = var.project_id
  display_name = "${var.alert_name_prefix} - Transaction ID utilisation (${var.cluster_id})"
  combiner     = "OR"
  severity     = "CRITICAL"

  conditions {
    display_name = "XID space consumed above critical threshold"

    condition_threshold {
      filter = <<-EOT
        metric.type = "alloydb.googleapis.com/database/postgresql/vacuum/transaction_id_utilization" AND
        ${local.cluster_filter}
      EOT

      # Fraction of the 2-billion XID space. A live instance read 0.0895.
      comparison      = "COMPARISON_GT"
      threshold_value = var.txid_utilization_critical
      duration        = "300s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MAX"
      }

      evaluation_missing_data = "EVALUATION_MISSING_DATA_INACTIVE"
    }
  }

  conditions {
    display_name = "XID space consumed above warning threshold"

    condition_threshold {
      filter = <<-EOT
        metric.type = "alloydb.googleapis.com/database/postgresql/vacuum/transaction_id_utilization" AND
        ${local.cluster_filter}
      EOT

      comparison      = "COMPARISON_GT"
      threshold_value = var.txid_utilization_warning
      duration        = "1800s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MAX"
      }

      evaluation_missing_data = "EVALUATION_MISSING_DATA_INACTIVE"
    }
  }

  notification_channels = var.notification_channel_ids

  alert_strategy {
    auto_close = "86400s"
  }

  documentation {
    mime_type = "text/markdown"
    subject   = "AlloyDB transaction ID utilisation rising on ${var.cluster_id}"
    content   = <<-EOT
      The transaction ID space on `${var.cluster_id}` is being consumed faster
      than autovacuum is freezing it.

      If this reaches 100% the database **stops accepting writes** until an
      offline vacuum completes. Treat sustained growth as an incident, not a
      warning.

      Autovacuum is almost never the root cause. Find what is blocking it:

      * `monitoring/sql/03_vacuum_and_bloat.sql` query C - checks all three
        blockers at once: long-running transactions, inactive replication
        slots, and orphaned prepared transactions.
      * Query B - identifies the specific table holding the oldest XID.

      ${local.runbook}
    EOT
  }
}

# ---------------------------------------------------------------------------
# 5. Storage quota exhaustion
#
# A ratio of usage to the quota limit. Note this is quota, not disk: AlloyDB
# storage grows automatically, but the per-cluster quota will fail writes.
# ---------------------------------------------------------------------------
resource "google_monitoring_alert_policy" "storage_quota" {
  count = local.enabled

  project      = var.project_id
  display_name = "${var.alert_name_prefix} - Storage quota utilisation (${var.cluster_id})"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "Cluster storage above fraction of quota"

    condition_threshold {
      filter = <<-EOT
        metric.type = "alloydb.googleapis.com/quota/storage_usage_per_cluster/usage" AND
        resource.type = "alloydb.googleapis.com/Cluster" AND
        resource.labels.cluster_id = "${var.cluster_id}"
      EOT

      denominator_filter = <<-EOT
        metric.type = "alloydb.googleapis.com/quota/storage_usage_per_cluster/limit" AND
        resource.type = "alloydb.googleapis.com/Cluster" AND
        resource.labels.cluster_id = "${var.cluster_id}"
      EOT

      comparison      = "COMPARISON_GT"
      threshold_value = var.storage_quota_threshold
      duration        = "600s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }

      denominator_aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }

      evaluation_missing_data = "EVALUATION_MISSING_DATA_INACTIVE"
    }
  }

  notification_channels = var.notification_channel_ids

  alert_strategy {
    auto_close = "86400s"
  }

  documentation {
    mime_type = "text/markdown"
    subject   = "AlloyDB storage quota on ${var.cluster_id}"
    content   = <<-EOT
      Cluster `${var.cluster_id}` is approaching its storage quota.

      The default quota is 16 TiB per cluster and the maximum supported is
      128 TiB. Exceeding it fails writes with
      `AlloyDB instance exceeds available storage quota`.

      A quota increase is a support request, so it has lead time - act on the
      warning rather than the failure.

      Before requesting more: check for table bloat and unused indexes with
      `monitoring/sql/03_vacuum_and_bloat.sql` queries F and G.

      Source: https://cloud.google.com/alloydb/quotas

      ${local.runbook}
    EOT
  }
}

# ---------------------------------------------------------------------------
# 6. Read pool replication lag
# ---------------------------------------------------------------------------
resource "google_monitoring_alert_policy" "replication_lag" {
  count = local.enabled

  project      = var.project_id
  display_name = "${var.alert_name_prefix} - Replication lag high (${var.cluster_id})"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "Max read pool replication lag above threshold"

    condition_threshold {
      filter = <<-EOT
        metric.type = "alloydb.googleapis.com/instance/postgres/replication/maximum_lag" AND
        ${local.cluster_filter}
      EOT

      comparison      = "COMPARISON_GT"
      threshold_value = var.replication_lag_ms_threshold
      duration        = "300s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MAX"
      }

      evaluation_missing_data = "EVALUATION_MISSING_DATA_INACTIVE"
    }
  }

  notification_channels = var.notification_channel_ids

  alert_strategy {
    auto_close = "3600s"
  }

  documentation {
    mime_type = "text/markdown"
    subject   = "AlloyDB replication lag on ${var.cluster_id}"
    content   = <<-EOT
      Read pool nodes on `${var.cluster_id}` are behind the primary by more
      than ${var.replication_lag_ms_threshold} ms. Reads served from the pool
      are correspondingly stale.

      Usual causes:

      * Read pool nodes materially smaller than the primary, so they cannot
        keep up with WAL apply. Size read nodes relative to the primary.
      * A heavy bulk write or index build on the primary.
      * Read traffic on the pool competing with replay for CPU.

      ${local.runbook}
    EOT
  }
}

# ---------------------------------------------------------------------------
# 7. Node down
# ---------------------------------------------------------------------------
resource "google_monitoring_alert_policy" "node_down" {
  count = local.enabled

  project      = var.project_id
  display_name = "${var.alert_name_prefix} - Node reported down (${var.cluster_id})"
  combiner     = "OR"
  severity     = "CRITICAL"

  conditions {
    display_name = "One or more nodes in down state"

    condition_threshold {
      filter = <<-EOT
        metric.type = "alloydb.googleapis.com/instance/postgres/instances" AND
        metric.labels.status = "down" AND
        ${local.cluster_filter}
      EOT

      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "120s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MAX"
      }

      evaluation_missing_data = "EVALUATION_MISSING_DATA_INACTIVE"
    }
  }

  notification_channels = var.notification_channel_ids

  alert_strategy {
    auto_close = "1800s"
  }

  documentation {
    mime_type = "text/markdown"
    subject   = "AlloyDB node down on ${var.cluster_id}"
    content   = <<-EOT
      At least one node of `${var.cluster_id}` is reporting `down`.

      For a REGIONAL (HA) instance this may be a failover in progress, which
      is expected to be brief and self-healing. Connections are dropped during
      a failover, so also confirm the application reconnected.

      For a ZONAL instance there is no automatic failover.

      ${local.runbook}
    EOT
  }
}

# ---------------------------------------------------------------------------
# 8. Backup freshness
#
# cluster/last_backup_timestamp is the creation time of the newest backup, in
# microseconds. Comparing it to now gives you "backups have silently stopped",
# which is otherwise invisible until the day you need a restore.
# ---------------------------------------------------------------------------
resource "google_monitoring_alert_policy" "backup_stale" {
  count = local.enabled

  project      = var.project_id
  display_name = "${var.alert_name_prefix} - No recent backup (${var.cluster_id})"
  combiner     = "OR"
  severity     = "CRITICAL"

  conditions {
    display_name = "Newest backup older than threshold"

    condition_monitoring_query_language {
      # MQL is used here because we need arithmetic against the current time,
      # which a plain threshold condition cannot express.
      query = <<-EOT
        fetch alloydb.googleapis.com/Cluster
        | metric 'alloydb.googleapis.com/cluster/last_backup_timestamp'
        | filter resource.cluster_id == '${var.cluster_id}'
        | group_by [], [latest_backup_us: max(value.last_backup_timestamp)]
        | every 30m
        | condition latest_backup_us < (end() - ${var.backup_max_age_hours}h)
      EOT

      duration = "1800s"
    }
  }

  notification_channels = var.notification_channel_ids

  alert_strategy {
    auto_close = "86400s"
  }

  documentation {
    mime_type = "text/markdown"
    subject   = "AlloyDB backups stale on ${var.cluster_id}"
    content   = <<-EOT
      No backup newer than ${var.backup_max_age_hours} hours exists for
      `${var.cluster_id}`.

      Verify the automated backup policy is still enabled and succeeding:

      ```bash
      gcloud alloydb backups list \
        --region=REGION \
        --filter="clusterName~${var.cluster_id}" \
        --format="table(name,state,createTime,sizeBytes)"
      ```

      Note this covers scheduled backups only. Continuous backup / PITR is a
      separate mechanism with its own recovery window - confirm both.

      ${local.runbook}
    EOT
  }
}

# ---------------------------------------------------------------------------
# 9. Audit log pipeline backlog
#
# Only useful when pgAudit is enabled. A growing backlog means audit records
# are buffered on the node and at risk - a compliance problem you will not
# otherwise notice.
# ---------------------------------------------------------------------------
resource "google_monitoring_alert_policy" "audit_backlog" {
  count = var.enabled && var.enable_audit_backlog_alert ? 1 : 0

  project      = var.project_id
  display_name = "${var.alert_name_prefix} - Audit log backlog (${var.cluster_id})"
  combiner     = "OR"
  severity     = "CRITICAL"

  conditions {
    display_name = "pgAudit shipping backlog above threshold"

    condition_threshold {
      filter = <<-EOT
        metric.type = "alloydb.googleapis.com/node/database/logging/audit/backlog_bytes_count" AND
        resource.type = "alloydb.googleapis.com/InstanceNode" AND
        resource.labels.cluster_id = "${var.cluster_id}"
      EOT

      comparison      = "COMPARISON_GT"
      threshold_value = var.audit_backlog_bytes_threshold
      duration        = "600s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MAX"
        # Group by node so one struggling node is not averaged away.
        cross_series_reducer = "REDUCE_MAX"
        group_by_fields      = ["resource.label.instance_id"]
      }

      evaluation_missing_data = "EVALUATION_MISSING_DATA_INACTIVE"
    }
  }

  notification_channels = var.notification_channel_ids

  alert_strategy {
    auto_close = "3600s"
  }

  documentation {
    mime_type = "text/markdown"
    subject   = "AlloyDB audit log backlog on ${var.cluster_id}"
    content   = <<-EOT
      pgAudit records are accumulating on `${var.cluster_id}` faster than they
      are being shipped to Cloud Logging.

      **Treat this as a compliance incident.** A sustained backlog means audit
      coverage has gaps, and gaps discovered during an audit are expensive.

      Most likely cause is audit volume: `pgaudit.log = all` on a busy OLTP
      database generates an enormous stream. Consider narrowing the audit
      classes, scoping auditing per role or database, or enabling
      `alloydb.enable_auditlog_volume_reduction`.

      See docs/04-operations/audit-logging-and-siem.md.

      ${local.runbook}
    EOT
  }
}

# ---------------------------------------------------------------------------
# Dashboard
# ---------------------------------------------------------------------------
resource "google_monitoring_dashboard" "alloydb" {
  count = var.enabled && var.create_dashboard ? 1 : 0

  project = var.project_id

  # Template lives inside the module so the module stays self-contained and
  # can be vendored or moved without breaking. An equivalent standalone JSON
  # for console import lives in monitoring/dashboards/.
  dashboard_json = templatefile(
    "${path.module}/dashboard.json.tftpl",
    {
      cluster_id   = var.cluster_id
      display_name = "${var.alert_name_prefix} Overview - ${var.cluster_id}"
    }
  )
}
