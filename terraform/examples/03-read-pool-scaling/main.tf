# ===========================================================================
# 03 - Read pool scaling
#
# Horizontal read scaling, and the workload-isolation pattern that matters
# more than the raw node count.
#
# The key architectural point: read pool nodes do NOT get their own copy of
# the data. AlloyDB's storage is regional and shared, so adding a read node
# adds compute and cache, not storage. That is why read pools scale out
# quickly and cheaply compared to traditional read replicas.
#
# BUDGET: 20 read pool nodes per cluster, summed across all read pool
# instances. Plan the split before you hit the ceiling.
#
# PSC NOTE: on the PSC path every instance - the primary AND each read pool -
# publishes its own service attachment and therefore needs its own consumer
# endpoint. That is visible at the bottom of this file, where the endpoints
# are created with for_each over the pools.
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

  # PSC, not PSA. See terraform/examples/README.md.
  enable_psa                   = false
  enable_private_google_access = true
}

module "alloydb" {
  source = "../../modules/alloydb-cluster"

  project_id = var.project_id
  region     = var.region
  cluster_id = "${var.name_prefix}-readscale"

  # --- Networking (PSC) ---
  psc_enabled = true
  psc_allowed_consumer_projects = length(var.psc_allowed_consumer_projects) > 0 ? (
    var.psc_allowed_consumer_projects
  ) : [data.google_project.this.number]

  cpu_count             = var.primary_cpu_count
  availability_type     = "REGIONAL"
  initial_user_password = var.initial_user_password
  ssl_mode              = "ENCRYPTED_ONLY"

  # Flags applied to the primary. The module merges these into each read pool
  # underneath the pool's own overrides, which keeps the
  # "read pool max_connections >= primary max_connections" rule satisfied by
  # default.
  database_flags = {
    "idle_in_transaction_session_timeout" = "60000"
    "log_min_duration_statement"          = "1000"
  }

  # -------------------------------------------------------------------------
  # Two read pools, separated by WORKLOAD rather than by size.
  #
  # This is the part worth copying. A single large pool means one runaway
  # analytics query competes with latency-sensitive application reads. Two
  # pools give you a blast radius boundary you can reason about, and let you
  # tune flags differently for each.
  # -------------------------------------------------------------------------
  read_pool_instances = {
    # Pool 1: application read traffic. Latency sensitive, high concurrency,
    # small queries. Sized like the primary so it keeps up with WAL apply.
    "${var.name_prefix}-readscale-app" = {
      node_count = var.app_pool_nodes
      cpu_count  = var.primary_cpu_count

      database_flags = {
        # Short timeout: an application read that takes 30s is a bug, and
        # failing fast protects the pool from queueing.
        "statement_timeout" = "30000" # 30s
      }
    }

    # Pool 2: analytics and reporting. Tolerates latency, runs big scans.
    # Deliberately isolated so a BI tool cannot degrade the application.
    "${var.name_prefix}-readscale-analytics" = {
      node_count = var.analytics_pool_nodes
      cpu_count  = var.analytics_cpu_count

      database_flags = {
        # Long-running reports are expected here.
        "statement_timeout" = "1800000" # 30 min

        # Bigger work_mem for sorts and hash joins. Safe here precisely
        # because this pool carries few concurrent sessions - work_mem is
        # per operation per session, so it multiplies with concurrency.
        "work_mem" = "262144" # 256 MB, in KB

        # The columnar engine turns large scans into vectorised columnar
        # scans. Enabling it here rather than on the primary means analytical
        # acceleration costs no memory on the write path.
        # NOTE: requires an instance restart.
        "google_columnar_engine.enabled" = "on"
      }
    }
  }

  automated_backup = {
    enabled         = true
    start_hour      = 2
    retention_count = 14
  }

  continuous_backup_enabled              = true
  continuous_backup_recovery_window_days = 7

  deletion_protection = false
  deletion_policy     = "FORCE"

  labels = {
    env        = "demo"
    managed_by = "terraform"
    pattern    = "read-scaling"
  }

  depends_on = [module.network]
}

# ---------------------------------------------------------------------------
# Consumer-side PSC endpoints
#
# One per instance. This is the detail that surprises people when they move
# read pools onto PSC: the primary and every read pool each publish their own
# service attachment, so "add a read pool" is also "add an endpoint, and a DNS
# record for it".
#
# The upside is that reachability becomes per-instance. You can expose the app
# read pool to one consumer project and keep the analytics pool and the primary
# somewhere else entirely, which is difficult to express with PSA.
# ---------------------------------------------------------------------------
module "psc_endpoint_primary" {
  source = "../../modules/psc-endpoint"

  project_id = var.project_id
  region     = var.region
  name       = "${var.name_prefix}-readscale-primary-psc"

  network_self_link = module.network.network_self_link
  subnet_self_link  = module.network.subnet_self_link

  service_attachment_link = module.alloydb.psc_service_attachment_link

  create_dns = var.create_psc_dns
  dns_name   = module.alloydb.psc_dns_name
}

module "psc_endpoint_read_pool" {
  source = "../../modules/psc-endpoint"

  for_each = module.alloydb.read_pool_psc_service_attachment_links

  project_id = var.project_id
  region     = var.region
  name       = "${each.key}-psc"

  network_self_link = module.network.network_self_link
  subnet_self_link  = module.network.subnet_self_link

  service_attachment_link = each.value

  create_dns = var.create_psc_dns
  dns_name   = module.alloydb.read_pool_psc_dns_names[each.key]
}

module "observability" {
  source = "../../modules/observability"

  project_id = var.project_id
  cluster_id = module.alloydb.cluster_id

  alert_name_prefix = "${var.name_prefix}-readscale"

  # Read pools are where replication lag actually shows up. Tighten this to
  # match the staleness the application can tolerate.
  replication_lag_ms_threshold = var.replication_lag_ms_threshold

  depends_on = [module.alloydb]
}

# ---------------------------------------------------------------------------
# Guard rail: AlloyDB caps read pool nodes at 20 per CLUSTER, summed across
# every read pool instance - not 20 per pool. Exceeding it fails at apply time
# with an opaque API error, so catch it at plan time instead.
#
# This is a `check` block rather than a variable validation because the limit
# is a property of the pair of variables, not of either one alone.
# ---------------------------------------------------------------------------
check "read_pool_node_budget" {
  assert {
    condition     = var.app_pool_nodes + var.analytics_pool_nodes <= 20
    error_message = "AlloyDB allows a maximum of 20 read pool nodes per cluster, summed across all read pool instances."
  }
}

