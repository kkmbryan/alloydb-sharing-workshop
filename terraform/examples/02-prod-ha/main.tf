# ===========================================================================
# 02 - Production HA
#
# The reference production deployment. If you copy one example, copy this one.
#
# What this adds over 01-dev-minimal:
#   * REGIONAL availability (active + standby in different zones)
#   * a tuned production flag set
#   * full alerting and a dashboard
#   * Managed Connection Pooling
#   * IAM database authentication
#   * pgAudit enabled
#   * real backup retention and a maintenance window
#   * deletion protection ON
#
# vCPU QUOTA: a REGIONAL primary runs TWO VMs. At 8 vCPU that is 16 vCPUs of
# quota, before any read pools. Check the `vcpu_quota_consumed` output.
# ===========================================================================

# PSC allow-lists consumer PROJECT NUMBERS, not project IDs.
data "google_project" "this" {
  project_id = var.project_id
}

module "network" {
  source = "../../modules/network"

  project_id  = var.project_id
  region      = var.region
  name_prefix = var.name_prefix
  subnet_cidr = var.subnet_cidr

  # Private Service Connect, not Private Services Access. No VPC peering, no
  # /16 handed to Google's producer network, and no transitive reachability
  # from peered VPCs - which is usually the deciding argument in a security
  # review. See terraform/examples/README.md.
  enable_psa = false

  # Lets the Auth Proxy reach googleapis.com from hosts with no public IP.
  enable_private_google_access = true
}

module "alloydb" {
  source = "../../modules/alloydb-cluster"

  project_id = var.project_id
  region     = var.region
  cluster_id = "${var.name_prefix}-prod"

  # --- Networking (PSC) ---
  # The cluster is not attached to your VPC. It publishes a service attachment
  # and you create an endpoint pointing at it, further down this file.
  #
  # PSA and PSC are mutually exclusive and cannot be changed after the cluster
  # is created. Moving between them means a new cluster and a data migration,
  # so this is worth getting right the first time.
  psc_enabled = true
  psc_allowed_consumer_projects = length(var.psc_allowed_consumer_projects) > 0 ? (
    var.psc_allowed_consumer_projects
  ) : [data.google_project.this.number]

  # --- Compute ---
  cpu_count = var.cpu_count

  # REGIONAL is required for the HA SLA. This provisions a standby node in a
  # second zone that shares the same regional storage, so failover does not
  # involve copying data.
  availability_type = "REGIONAL"

  # --- Access ---
  initial_user_password = var.initial_user_password
  ssl_mode              = "ENCRYPTED_ONLY"

  # Set true to forbid direct connections and require the Auth Proxy or a
  # language connector. Strongest control; breaks plain psql. Decide
  # deliberately - see docs/security-hardening.md.
  require_connectors = var.require_connectors

  # --- Production flag baseline ---
  # Mirrors config/database-flags/production-oltp.env. Keep the two in sync.
  database_flags = {
    # --- Connection hygiene ---
    # Do NOT raise max_connections to solve concurrency - use the pooler
    # configured below. Left at the AlloyDB default of 1000.
    "idle_in_transaction_session_timeout" = "60000"  # 60s
    "statement_timeout"                   = "300000" # 5 min backstop

    # --- Observability ---
    "log_min_duration_statement" = "1000" # log queries over 1s
    "log_checkpoints"            = "on"
    "log_lock_waits"             = "on"
    "log_temp_files"             = "0" # log every temp file spill

    # --- Security: IAM database authentication ---
    # Confirmed: this flag does NOT require an instance restart.
    "alloydb.iam_authentication" = "on"

    # --- Security: audit logging ---
    # alloydb.enable_pgaudit DOES require a restart. pgaudit.log defaults to
    # none, so without setting it you enable the extension and capture nothing.
    "alloydb.enable_pgaudit" = "on"
    # ddl + role captures schema changes and privilege changes - high value,
    # low volume. Add 'write' or 'read' only after measuring log volume; see
    # docs/audit-logging-and-siem.md.
    "pgaudit.log" = "ddl,role"

    # --- Security: password policy for built-in users ---
    "password.enforce_complexity"                         = "on"
    "password.min_pass_length"                            = "16"
    "password.enforce_password_does_not_contain_username" = "on"

    # --- Security: restrict reading password hashes ---
    # Without this, any user can read pg_authid / pg_shadow and walk away with
    # every password hash in the cluster.
    "alloydb.pg_authid_select_role" = "alloydbsuperuser"
    "alloydb.pg_shadow_select_role" = "alloydbsuperuser"
  }

  # --- Managed Connection Pooling ---
  # Flag keys drop the "connection-pooling-" CLI prefix and use underscores.
  connection_pool = {
    enabled = true
    flags = {
      # Transaction mode gives the largest multiplexing benefit and is the
      # right default for most OLTP applications. It is worth checking the
      # application first, since transaction mode does not support
      # session-scoped SET/RESET, session-level advisory locks, LISTEN,
      # WITH HOLD cursors, PREPARE/DEALLOCATE, LOAD, PRESERVE/DELETE ROW temp
      # tables or protocol-level prepared plans. Use "session" mode if any of
      # those are needed. See
      # config/connection-pooling/managed-connection-pooling.md.
      "pool_mode" = "transaction"
    }
  }

  # --- Backups ---
  automated_backup = {
    enabled         = true
    days_of_week    = ["MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY", "SUNDAY"]
    start_hour      = 2
    retention_count = 30
  }

  # Continuous backup is what gives you point-in-time recovery. The window is
  # your worst-case "restore to just before the bad migration" horizon.
  continuous_backup_enabled              = true
  continuous_backup_recovery_window_days = 14

  # --- Maintenance ---
  # Maintenance drops connections briefly. Pick a genuinely low-traffic hour
  # in the cluster's own timezone and make sure clients retry.
  maintenance_window = {
    day   = "SUNDAY"
    hours = 4
  }

  # --- Lifecycle ---
  # Destroying this requires setting deletion_protection = false and applying
  # that change BEFORE running destroy. That two-step is the point.
  deletion_protection = var.deletion_protection
  deletion_policy     = "DEFAULT"

  labels = {
    env        = "prod"
    managed_by = "terraform"
    tier       = "critical"
  }

  depends_on = [module.network]
}

# ---------------------------------------------------------------------------
# Consumer-side PSC endpoint
#
# With PSA, Google places a private IP inside your VPC for you. With PSC you
# create the endpoint yourself: an internal address plus a forwarding rule
# that targets the cluster's service attachment. That extra step is the price
# of not peering your VPC to Google's producer network.
#
# The endpoint is REGIONAL. A multi-region deployment needs one per region -
# see 05-cross-region-dr.
# ---------------------------------------------------------------------------
module "psc_endpoint" {
  source = "../../modules/psc-endpoint"

  project_id = var.project_id
  region     = var.region
  name       = "${var.name_prefix}-prod-psc"

  network_self_link = module.network.network_self_link
  subnet_self_link  = module.network.subnet_self_link

  service_attachment_link = module.alloydb.psc_service_attachment_link

  # Pin the endpoint IP in production so firewall rules, IPAM records and
  # runbooks can reference a stable address.
  ip_address = var.psc_endpoint_ip

  # Off by default: most organisations manage DNS centrally. If you leave it
  # off, create the A record from the psc_endpoint_summary output. Nothing
  # resolves until you do.
  create_dns = var.create_psc_dns
  dns_name   = module.alloydb.psc_dns_name

  labels = {
    env        = "prod"
    managed_by = "terraform"
  }
}

# ---------------------------------------------------------------------------
# IAM database user for the application
#
# No password anywhere: the application authenticates with its Google Cloud
# identity and a short-lived token. This removes an entire class of secret
# management problems.
#
# The user_id for a service account is its email with the
# ".gserviceaccount.com" suffix removed, because PostgreSQL role names are
# capped at 63 characters.
# ---------------------------------------------------------------------------
resource "google_alloydb_user" "app_iam" {
  count = var.app_service_account_email == null ? 0 : 1

  cluster   = module.alloydb.cluster_name
  user_id   = trimsuffix(var.app_service_account_email, ".gserviceaccount.com")
  user_type = "ALLOYDB_IAM_USER"

  # database_roles is authoritative - roles granted out of band via SQL are
  # stripped on the next apply. Manage membership here, object privileges
  # with GRANT.
  database_roles = ["alloydbiamuser"]

  # The users API talks to a running primary instance.
  depends_on = [module.alloydb]
}

# ---------------------------------------------------------------------------
# Least-privilege IAM for the application service account
#
# alloydb.client  -> may open a connection via the Auth Proxy / connectors
# alloydb.databaseUser -> may authenticate as a database user
#
# Deliberately NOT alloydb.admin: the application must never be able to
# delete the cluster it depends on.
# ---------------------------------------------------------------------------
resource "google_project_iam_member" "app_alloydb_client" {
  count = var.app_service_account_email == null ? 0 : 1

  project = var.project_id
  role    = "roles/alloydb.client"
  member  = "serviceAccount:${var.app_service_account_email}"
}

resource "google_project_iam_member" "app_alloydb_db_user" {
  count = var.app_service_account_email == null ? 0 : 1

  project = var.project_id
  role    = "roles/alloydb.databaseUser"
  member  = "serviceAccount:${var.app_service_account_email}"
}

# ---------------------------------------------------------------------------
# Data Access audit logs
#
# OFF by default and billable. pgAudit records are delivered as Data Access
# logs, so enabling pgAudit without this produces nothing useful.
# ---------------------------------------------------------------------------
resource "google_project_iam_audit_config" "alloydb" {
  count = var.enable_data_access_logs ? 1 : 0

  project = var.project_id
  service = "alloydb.googleapis.com"

  audit_log_config {
    log_type = "ADMIN_READ"
  }
  audit_log_config {
    log_type = "DATA_READ"
  }
  audit_log_config {
    log_type = "DATA_WRITE"
  }
}

# ---------------------------------------------------------------------------
# Monitoring
# ---------------------------------------------------------------------------
resource "google_monitoring_notification_channel" "email" {
  count = var.alert_email == null ? 0 : 1

  project      = var.project_id
  display_name = "${var.name_prefix} AlloyDB alerts"
  type         = "email"

  labels = {
    email_address = var.alert_email
  }
}

module "observability" {
  source = "../../modules/observability"

  project_id = var.project_id
  cluster_id = module.alloydb.cluster_id

  notification_channel_ids = var.alert_email == null ? [] : [
    google_monitoring_notification_channel.email[0].id
  ]

  alert_name_prefix = "${var.name_prefix}-prod"

  # Memory is an absolute byte threshold, so it must track the instance shape.
  # Roughly 12% of RAM, assuming the ~8 GiB per vCPU highmem convention.
  # Re-check this against the actual shape you deploy.
  memory_available_bytes_threshold = var.cpu_count * 8 * 1024 * 1024 * 1024 / 8

  # pgAudit is on above, so watch the audit shipping pipeline for backlog.
  enable_audit_backlog_alert = true

  depends_on = [module.alloydb]
}
