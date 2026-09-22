# ===========================================================================
# 01 - Dev / minimal
#
# The smallest sensible AlloyDB deployment. Read this one first.
#
# What this shows:
#   * VPC + Private Service Connect, which is the connectivity prerequisite
#     almost everyone forgets on their first attempt
#   * a single ZONAL instance - cheapest, no HA
#   * how the cluster/instance split works
#
# What this deliberately does NOT do:
#   * no HA          -> see 02-prod-ha
#   * no read pools  -> see 03-read-pool-scaling
#   * no CMEK        -> see 04-secure-cmek
#   * no monitoring  -> see 02-prod-ha
#
# NOT FOR PRODUCTION. A ZONAL instance has no automatic failover and is not
# covered by the HA SLA.
# ===========================================================================

# The cluster allow-lists consumer PROJECT NUMBERS, not project IDs, so we look
# this project's number up rather than asking you to paste it in.
data "google_project" "this" {
  project_id = var.project_id
}

module "network" {
  source = "../../modules/network"

  project_id  = var.project_id
  region      = var.region
  name_prefix = var.name_prefix
  subnet_cidr = var.subnet_cidr

  # PSC does not use Private Services Access, so there is no VPC peering and
  # no IP range shared with Google's producer network. Every example in this
  # repo uses PSC - see terraform/examples/README.md for the reasoning.
  enable_psa = false

  # The Auth Proxy reaches googleapis.com from hosts that have no public IP.
  enable_private_google_access = true
}

module "alloydb" {
  source = "../../modules/alloydb-cluster"

  project_id = var.project_id
  region     = var.region
  cluster_id = "${var.name_prefix}-dev"

  # --- Networking (PSC) ---
  # The cluster publishes a service attachment and the consumer project creates
  # an endpoint pointing at it. Note there is no network_self_link here: with
  # PSC the cluster is not attached to your VPC at all.
  psc_enabled = true
  psc_allowed_consumer_projects = length(var.psc_allowed_consumer_projects) > 0 ? (
    var.psc_allowed_consumer_projects
  ) : [data.google_project.this.number]

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

  # The subnet must exist before the cluster, and later the endpoint.
  depends_on = [module.network]
}

# ---------------------------------------------------------------------------
# Consumer-side PSC endpoint
#
# This is the part that catches people moving over from PSA. With PSA, Google
# hands you a private IP inside your own VPC and you are done. With PSC you
# create the endpoint yourself: an internal address plus a forwarding rule that
# targets the cluster's service attachment.
#
# The endpoint is a REGIONAL resource, so a multi-region deployment needs one
# per region - see 05-cross-region-dr.
# ---------------------------------------------------------------------------
module "psc_endpoint" {
  source = "../../modules/psc-endpoint"

  project_id = var.project_id
  region     = var.region
  name       = "${var.name_prefix}-dev-psc"

  network_self_link = module.network.network_self_link
  subnet_self_link  = module.network.subnet_self_link

  service_attachment_link = module.alloydb.psc_service_attachment_link

  # Off by default. If you leave it off, create the A record yourself from the
  # psc_endpoint output - nothing resolves until you do.
  create_dns = var.create_psc_dns
  dns_name   = module.alloydb.psc_dns_name

  labels = {
    env      = "dev"
    workshop = "alloydb-operations"
  }
}
