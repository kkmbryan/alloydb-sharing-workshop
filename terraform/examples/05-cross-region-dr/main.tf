# ===========================================================================
# 05 - Cross-region disaster recovery
#
# A primary cluster in one region and a continuously replicated, read-only
# SECONDARY cluster in another.
#
# WHAT THIS PROTECTS AGAINST, AND WHAT IT DOES NOT
#
#   Protects against: loss of an entire region.
#
#   Does NOT protect against: logical corruption. A bad migration or a
#   malicious DELETE replicates to the secondary within seconds. Your defence
#   there is continuous backup and point-in-time recovery, which is why both
#   are configured here. Cross-region replication and PITR solve different
#   problems and you need both.
#
# HA vs DR - do not confuse them:
#   availability_type = REGIONAL  -> survives a ZONE failure, RPO 0, automatic
#   secondary cluster             -> survives a REGION failure, RPO = the
#                                    replication lag at the moment of failure,
#                                    and the failover is a human decision
#
# The two are complementary. This example uses both.
# ===========================================================================

# ---------------------------------------------------------------------------
# Networking in both regions
#
# PSA is per-VPC-per-producer, so a single VPC with a subnet in each region
# works. The reserved PSA range is global to the VPC and serves both.
# ---------------------------------------------------------------------------
module "network_primary" {
  source = "../../modules/network"

  project_id  = var.project_id
  region      = var.primary_region
  name_prefix = var.name_prefix
  subnet_cidr = var.primary_subnet_cidr

  create_network = true
  enable_psa     = true
}

module "network_secondary" {
  source = "../../modules/network"

  project_id  = var.project_id
  region      = var.secondary_region
  name_prefix = "${var.name_prefix}-dr"
  subnet_cidr = var.secondary_subnet_cidr

  # Reuse the VPC and its existing PSA peering.
  create_network        = false
  existing_network_name = module.network_primary.network_name
  enable_psa            = false

  depends_on = [module.network_primary]
}

# ---------------------------------------------------------------------------
# Values shared between the primary and the secondary.
#
# These are deliberately hoisted into locals rather than repeated. A secondary
# cluster does NOT inherit database flags from its primary - flags are an
# instance-level property, and the secondary has its own instance. If you let
# the two drift, a promote silently changes your runtime configuration at the
# worst possible moment. Keep them identical and let promote be boring.
# ---------------------------------------------------------------------------
locals {
  database_flags = {
    "idle_in_transaction_session_timeout" = "60000"
    "log_min_duration_statement"          = "1000"
  }

  # Referenced by outputs.tf so the DR runbook can never quote a stale number.
  pitr_window_days = 14
}

# ---------------------------------------------------------------------------
# Primary cluster
# ---------------------------------------------------------------------------
module "alloydb_primary" {
  source = "../../modules/alloydb-cluster"

  project_id = var.project_id
  region     = var.primary_region
  cluster_id = "${var.name_prefix}-primary"

  cluster_type = "PRIMARY"

  network_self_link  = module.network_primary.network_self_link
  allocated_ip_range = module.network_primary.psa_range_name

  cpu_count = var.cpu_count

  # Zone-level HA within the primary region, on top of region-level DR.
  availability_type = "REGIONAL"

  initial_user_password = var.initial_user_password
  ssl_mode              = "ENCRYPTED_ONLY"

  database_flags = local.database_flags

  # PITR is the defence against logical corruption that replication cannot
  # help with. Keep the window generous.
  continuous_backup_enabled              = true
  continuous_backup_recovery_window_days = local.pitr_window_days


  automated_backup = {
    enabled         = true
    start_hour      = 2
    retention_count = 30
  }

  deletion_protection = false
  deletion_policy     = "FORCE"

  labels = {
    env        = "dr-demo"
    role       = "primary"
    managed_by = "terraform"
  }

  depends_on = [module.network_primary]
}

# ---------------------------------------------------------------------------
# Secondary (DR) cluster
#
# Continuously and asynchronously replicated from the primary. Read-only
# until promoted or switched over.
#
# Match the secondary's shape to the primary. An undersized secondary falls
# behind on apply, which increases your RPO exactly when you can least afford
# it, and leaves you with insufficient capacity after a failover.
# ---------------------------------------------------------------------------
module "alloydb_secondary" {
  source = "../../modules/alloydb-cluster"

  project_id = var.project_id
  region     = var.secondary_region
  cluster_id = "${var.name_prefix}-secondary"

  cluster_type         = "SECONDARY"
  primary_cluster_name = module.alloydb_primary.cluster_name

  network_self_link  = module.network_primary.network_self_link
  allocated_ip_range = module.network_primary.psa_range_name

  # Same shape as the primary. Do not economise here.
  cpu_count         = var.cpu_count
  availability_type = "REGIONAL"

  ssl_mode = "ENCRYPTED_ONLY"

  # Identical to the primary. See the locals block above for why this matters:
  # after a promote this instance IS the primary, and you do not want its
  # timeouts and logging thresholds to change at that moment.
  database_flags = local.database_flags

  # A secondary cluster takes no initial_user, no automated backup policy and
  # no continuous backup config - it inherits its data from the primary. The
  # module handles suppressing those blocks based on cluster_type.
  automated_backup = null

  # FORCE is REQUIRED to destroy a secondary cluster: its instance cannot be
  # deleted independently of the cluster.
  deletion_protection = false
  deletion_policy     = "FORCE"

  labels = {
    env        = "dr-demo"
    role       = "secondary"
    managed_by = "terraform"
  }

  depends_on = [
    module.alloydb_primary,
    module.network_secondary,
  ]
}

# ---------------------------------------------------------------------------
# Monitoring on both sides
#
# Monitoring the secondary is not optional. A silently broken replica is
# worse than no replica, because you believe you are protected.
# ---------------------------------------------------------------------------
module "observability_primary" {
  source = "../../modules/observability"

  project_id        = var.project_id
  cluster_id        = module.alloydb_primary.cluster_id
  alert_name_prefix = "${var.name_prefix}-primary"

  depends_on = [module.alloydb_primary]
}

module "observability_secondary" {
  source = "../../modules/observability"

  project_id        = var.project_id
  cluster_id        = module.alloydb_secondary.cluster_id
  alert_name_prefix = "${var.name_prefix}-secondary"

  # Cross-region lag is your live RPO measurement. Alert tightly on it: this
  # number IS your data loss exposure if the primary region disappears right
  # now.
  replication_lag_ms_threshold = var.dr_replication_lag_ms_threshold

  # The secondary has no backup policy of its own, so the backup-freshness
  # alert would fire permanently. Backups are taken on the primary.
  backup_max_age_hours = 87600 # effectively disabled

  depends_on = [module.alloydb_secondary]
}
