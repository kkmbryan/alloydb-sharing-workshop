# ===========================================================================
# 01 - Dev / minimal
#
# The smallest sensible AlloyDB deployment. Read this one first.
#
# What this shows:
#   * VPC + Private Services Access, which is the prerequisite almost everyone
#     forgets on their first attempt
#   * a single ZONAL instance - cheapest, no HA
#   * how the cluster/instance split works
#
# What this deliberately does NOT do:
#   * no HA          -> see 02-prod-ha
#   * no read pools  -> see 03-read-pool-scaling
#   * no CMEK or PSC -> see 04-secure-cmek-psc
#   * no monitoring  -> see 02-prod-ha
#
# NOT FOR PRODUCTION. A ZONAL instance has no automatic failover and is not
# covered by the HA SLA.
# ===========================================================================

module "network" {
  source = "../../modules/network"

  project_id  = var.project_id
  region      = var.region
  name_prefix = var.name_prefix
  subnet_cidr = var.subnet_cidr

  # Private Services Access must exist before the cluster is created.
  enable_psa = true
}

module "alloydb" {
  source = "../../modules/alloydb-cluster"

  project_id = var.project_id
  region     = var.region
  cluster_id = "${var.name_prefix}-dev"

  # --- Networking (PSA) ---
  network_self_link  = module.network.network_self_link
  allocated_ip_range = module.network.psa_range_name

  # --- Compute ---
  # 2 vCPU is the smallest generally-available N2 shape.
  cpu_count = 2

  # ZONAL: one node, no standby, no automatic failover.
  # This also halves the vCPU quota cost versus REGIONAL.
  availability_type = "ZONAL"

  # --- Access ---
  initial_user_password = var.initial_user_password

  # Encryption in transit is still enforced even in dev. There is no good
  # reason to allow unencrypted connections anywhere.
  ssl_mode = "ENCRYPTED_ONLY"

  # Left false so workshop attendees can connect with plain psql through the
  # Auth Proxy without extra setup friction.
  require_connectors = false

  # --- Flags ---
  database_flags = {
    # Kill sessions that sit idle inside a transaction. These hold locks and
    # block vacuum, and in a dev environment they are almost always an
    # abandoned psql window.
    "idle_in_transaction_session_timeout" = "300000" # 5 min, in ms

    # Log anything slower than 1s so attendees can see slow queries land in
    # Cloud Logging during the workshop.
    "log_min_duration_statement" = "1000"
  }

  # --- Managed Connection Pooling ---
  # AlloyDB has a pooler built into the service, so there is no PgBouncer VM to
  # run, patch or give its own credentials. It is disabled by default, so this
  # block is what turns it on. It listens on port 6432; direct connections
  # continue to use 5432.
  #
  # Flag keys drop the "connection-pooling-" CLI prefix and use underscores,
  # so --connection-pooling-pool-mode becomes "pool_mode".
  #
  # Session mode is used here rather than transaction mode. Transaction mode
  # multiplexes more aggressively and is the better production default, but it
  # does not support session-scoped SET, LISTEN, WITH HOLD cursors, session
  # advisory locks or protocol-level prepared statements - which would surprise
  # someone exploring with psql. See example 02 for transaction mode.
  #
  # Worth noting for a security review: managed connection pooling is not
  # supported on public IP connections, so enabling it reinforces a
  # private-only posture rather than working against it.
  connection_pool = {
    enabled = true
    flags = {
      "pool_mode" = "session"
    }
  }

  # --- Backups ---
  # Minimal retention: this is a throwaway environment.
  automated_backup = {
    enabled         = true
    days_of_week    = ["MONDAY", "WEDNESDAY", "FRIDAY"]
    start_hour      = 3
    retention_count = 3
  }

  continuous_backup_enabled              = true
  continuous_backup_recovery_window_days = 1

  # --- Lifecycle ---
  # Dev environments must be easy to destroy. Both guards are relaxed here;
  # see 02-prod-ha for the production posture.
  deletion_protection = false
  deletion_policy     = "FORCE"

  labels = {
    env        = "dev"
    managed_by = "terraform"
    workshop   = "alloydb-operations"
  }

  # The PSA peering must be established before the cluster is created.
  # Terraform cannot infer this from the network_self_link reference alone.
  depends_on = [module.network]
}
