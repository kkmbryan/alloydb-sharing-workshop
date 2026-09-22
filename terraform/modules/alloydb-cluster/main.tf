# ===========================================================================
# AlloyDB cluster + primary instance + optional read pools
#
# Design notes for workshop readers:
#
#  * The CLUSTER owns storage, backups, encryption and the network attachment.
#    The INSTANCE owns compute (vCPU/RAM), flags and connectivity settings.
#    That split is why resizing compute does not touch your data, and why read
#    pools do not need their own copy of the data.
#
#  * PSA and PSC are mutually exclusive and cannot be changed after creation.
#    We express that with dynamic blocks so exactly one is emitted.
# ===========================================================================

locals {
  primary_instance_id = coalesce(var.primary_instance_id, "${var.cluster_id}-primary")

  # Backups inherit the cluster key unless a dedicated backup key is supplied.
  effective_backup_kms_key = coalesce(var.backup_kms_key_name, var.kms_key_name, "")

  is_secondary = var.cluster_type == "SECONDARY"

  # A SECONDARY cluster is populated by replication, so it must not declare an
  # initial user, its own backup policy, or its own network attachment.
  create_initial_user = !local.is_secondary && var.initial_user_password != null
}

# ---------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------
resource "google_alloydb_cluster" "this" {
  cluster_id       = var.cluster_id
  location         = var.region
  project          = var.project_id
  cluster_type     = var.cluster_type
  database_version = var.database_version
  labels           = var.labels

  # Two independent delete guards. deletion_protection is the provider-side
  # guard; deletion_policy controls whether the API deletes child instances
  # along with the cluster.
  deletion_protection = var.deletion_protection
  deletion_policy     = var.deletion_policy

  # --- Networking: PSA ---
  dynamic "network_config" {
    for_each = var.psc_enabled ? [] : [1]
    content {
      network            = var.network_self_link
      allocated_ip_range = var.allocated_ip_range
    }
  }

  # --- Networking: PSC ---
  dynamic "psc_config" {
    for_each = var.psc_enabled ? [1] : []
    content {
      psc_enabled = true
    }
  }

  # --- Initial superuser ---
  # Only meaningful at create time. Stored in plaintext in state.
  dynamic "initial_user" {
    for_each = local.create_initial_user ? [1] : []
    content {
      user     = "postgres"
      password = var.initial_user_password
    }
  }

  # --- CMEK ---
  dynamic "encryption_config" {
    for_each = var.kms_key_name == null ? [] : [1]
    content {
      kms_key_name = var.kms_key_name
    }
  }

  # --- Cross-region replication ---
  dynamic "secondary_config" {
    for_each = local.is_secondary ? [1] : []
    content {
      primary_cluster_name = var.primary_cluster_name
    }
  }

  # --- Automated (scheduled) backups ---
  # Not valid on a secondary cluster: back up the primary instead.
  dynamic "automated_backup_policy" {
    for_each = (!local.is_secondary && var.automated_backup != null) ? [var.automated_backup] : []
    content {
      enabled       = try(automated_backup_policy.value.enabled, true)
      location      = var.region
      backup_window = "${try(automated_backup_policy.value.backup_window_seconds, 3600)}s"
      labels        = var.labels

      weekly_schedule {
        days_of_week = try(automated_backup_policy.value.days_of_week, ["SUNDAY"])
        start_times {
          hours   = try(automated_backup_policy.value.start_hour, 3)
          minutes = 0
          seconds = 0
          nanos   = 0
        }
      }

      # Exactly one retention strategy may be set.
      dynamic "quantity_based_retention" {
        for_each = try(automated_backup_policy.value.retention_count, null) != null ? [1] : []
        content {
          count = automated_backup_policy.value.retention_count
        }
      }

      dynamic "time_based_retention" {
        for_each = try(automated_backup_policy.value.retention_period_days, null) != null ? [1] : []
        content {
          retention_period = "${automated_backup_policy.value.retention_period_days * 86400}s"
        }
      }

      dynamic "encryption_config" {
        for_each = local.effective_backup_kms_key == "" ? [] : [1]
        content {
          kms_key_name = local.effective_backup_kms_key
        }
      }
    }
  }

  # --- Continuous backup (this is what enables PITR) ---
  dynamic "continuous_backup_config" {
    for_each = local.is_secondary ? [] : [1]
    content {
      enabled              = var.continuous_backup_enabled
      recovery_window_days = var.continuous_backup_recovery_window_days

      dynamic "encryption_config" {
        for_each = local.effective_backup_kms_key == "" ? [] : [1]
        content {
          kms_key_name = local.effective_backup_kms_key
        }
      }
    }
  }

  # --- Maintenance window ---
  dynamic "maintenance_update_policy" {
    for_each = var.maintenance_window == null ? [] : [1]
    content {
      maintenance_windows {
        day = var.maintenance_window.day
        start_time {
          # Only whole hours are supported; the API rejects non-zero
          # minutes/seconds/nanos.
          hours   = var.maintenance_window.hours
          minutes = 0
          seconds = 0
          nanos   = 0
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      # The initial user password is a create-time concern. Rotate it with
      # ALTER ROLE or Secret Manager, not by re-applying Terraform, so that a
      # changed variable does not try to recreate the cluster.
      initial_user,
    ]
  }
}

# ---------------------------------------------------------------------------
# Primary instance
# ---------------------------------------------------------------------------
resource "google_alloydb_instance" "primary" {
  cluster       = google_alloydb_cluster.this.name
  instance_id   = local.primary_instance_id
  instance_type = local.is_secondary ? "SECONDARY" : "PRIMARY"

  # REGIONAL provisions an active node plus a standby in another zone.
  availability_type = var.availability_type
  database_flags    = var.database_flags
  labels            = var.labels

  machine_config {
    cpu_count    = var.cpu_count
    machine_type = var.machine_type
  }

  # Public IP is off unless explicitly requested. authorized_external_networks
  # is only emitted when public IP is on - sending it otherwise is an API error.
  network_config {
    enable_public_ip = var.enable_public_ip

    dynamic "authorized_external_networks" {
      for_each = var.enable_public_ip ? var.authorized_external_networks : []
      content {
        cidr_range = authorized_external_networks.value
      }
    }
  }

  client_connection_config {
    require_connectors = var.require_connectors
    ssl_config {
      ssl_mode = var.ssl_mode
    }
  }

  dynamic "psc_instance_config" {
    for_each = var.psc_enabled ? [1] : []
    content {
      allowed_consumer_projects = var.psc_allowed_consumer_projects
    }
  }

  query_insights_config {
    query_string_length     = try(var.query_insights.query_string_length, 1024)
    record_application_tags = try(var.query_insights.record_application_tags, true)
    record_client_address   = try(var.query_insights.record_client_address, true)
    query_plans_per_minute  = try(var.query_insights.query_plans_per_minute, 5)
  }

  dynamic "connection_pool_config" {
    for_each = var.connection_pool == null ? [] : [var.connection_pool]
    content {
      enabled = connection_pool_config.value.enabled
      flags   = try(connection_pool_config.value.flags, {})
    }
  }

  lifecycle {
    ignore_changes = [
      # instance_type is ForceNew. During a promote or switchover the API
      # changes it out from under Terraform; without this, the next plan wants
      # to destroy and recreate the instance.
      instance_type,
    ]
  }
}

# ---------------------------------------------------------------------------
# Read pools
#
# Created after the primary. AlloyDB serialises instance operations within a
# cluster, so concurrent creates fail with a conflicting-operation error.
# ---------------------------------------------------------------------------
resource "google_alloydb_instance" "read_pool" {
  for_each = var.read_pool_instances

  cluster       = google_alloydb_cluster.this.name
  instance_id   = each.key
  instance_type = "READ_POOL"
  labels        = var.labels

  # A read pool's max_connections must be >= the primary's. Merging the
  # primary's flags underneath the pool's own overrides keeps that true by
  # default while still allowing read-specific tuning.
  database_flags = merge(var.database_flags, each.value.database_flags)

  machine_config {
    # Default a read pool node to the same shape as the primary. Undersized
    # read nodes fall behind on WAL apply and show up as replication lag.
    cpu_count    = coalesce(each.value.cpu_count, var.cpu_count)
    machine_type = each.value.machine_type
  }

  read_pool_config {
    node_count = each.value.node_count
  }

  network_config {
    enable_public_ip = var.enable_public_ip
  }

  client_connection_config {
    require_connectors = var.require_connectors
    ssl_config {
      ssl_mode = var.ssl_mode
    }
  }

  dynamic "psc_instance_config" {
    for_each = var.psc_enabled ? [1] : []
    content {
      allowed_consumer_projects = var.psc_allowed_consumer_projects
    }
  }

  depends_on = [google_alloydb_instance.primary]
}
