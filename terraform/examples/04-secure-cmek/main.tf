# ===========================================================================
# 04 - Hardened: CMEK + Private Service Connect + IAM auth + full audit
#
# The maximum-assurance reference. Everything here exists to satisfy a
# security review.
#
# Controls demonstrated:
#   1. Private Service Connect - no VPC peering, no public IP, explicit
#      per-project consumer allow-listing
#   2. CMEK with a customer-controlled, rotating KMS key
#   3. ENCRYPTED_ONLY plus require_connectors - no unencrypted and no direct
#      connections at all
#   4. IAM database authentication - no long-lived database passwords
#   5. pgAudit plus Data Access logs plus an export sink to a separate
#      security project
#   6. Restricted access to password hashes
#   7. Audit pipeline backlog alerting
#
# ORDERING MATTERS: the KMS grant to the AlloyDB service agent must land
# BEFORE the cluster is created, or creation fails with a permission error
# that does not obviously point at KMS.
# ===========================================================================

data "google_project" "this" {
  project_id = var.project_id
}

# ---------------------------------------------------------------------------
# 1. Cloud KMS
# ---------------------------------------------------------------------------
resource "google_kms_key_ring" "alloydb" {
  name    = "${var.name_prefix}-alloydb-kr"
  project = var.project_id

  # The key ring must be in the SAME region as the AlloyDB cluster.
  location = var.region
}

resource "google_kms_crypto_key" "alloydb" {
  name     = "${var.name_prefix}-alloydb-key"
  key_ring = google_kms_key_ring.alloydb.id
  purpose  = "ENCRYPT_DECRYPT"

  # Automatic rotation. AlloyDB picks up new key versions transparently;
  # existing data stays readable via the version it was encrypted with.
  rotation_period = var.key_rotation_period

  version_template {
    algorithm = "GOOGLE_SYMMETRIC_ENCRYPTION"
    # HSM-backed. Use "SOFTWARE" if FIPS 140-2 Level 3 is not required and
    # cost matters more.
    protection_level = var.kms_protection_level
  }

  # In production, prevent_destroy = true protects against accidental key loss.
  # Commented out for workshop/test lifecycles so terraform destroy can succeed.
  # lifecycle {
  #   prevent_destroy = true
  # }
}

# ---------------------------------------------------------------------------
# 2. AlloyDB service agent, and its grant on the key
#
# The service agent is created lazily on first use of the API. This resource
# forces it into existence so the IAM binding below has a principal to bind
# to, avoiding a two-phase apply.
# ---------------------------------------------------------------------------
resource "google_project_service" "alloydb" {
  project            = var.project_id
  service            = "alloydb.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service_identity" "alloydb" {
  provider = google-beta

  project = var.project_id
  service = "alloydb.googleapis.com"

  depends_on = [google_project_service.alloydb]
}

resource "google_kms_crypto_key_iam_member" "alloydb_agent" {
  crypto_key_id = google_kms_crypto_key.alloydb.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_project_service_identity.alloydb.email}"
}

# ---------------------------------------------------------------------------
# 3. Network
#
# PSC mode: no Private Services Access, no VPC peering. The consumer creates
# an endpoint in its own subnet, so there is no transitive routing exposure
# and no shared IP range with Google's producer network.
# ---------------------------------------------------------------------------
module "network" {
  source = "../../modules/network"

  project_id  = var.project_id
  region      = var.region
  name_prefix = var.name_prefix
  subnet_cidr = var.subnet_cidr

  # PSC does not use PSA.
  enable_psa = false

  # The Auth Proxy needs to reach googleapis.com from a private-only host.
  enable_private_google_access = true
}

# ---------------------------------------------------------------------------
# 4. The cluster
# ---------------------------------------------------------------------------
module "alloydb" {
  source = "../../modules/alloydb-cluster"

  project_id = var.project_id
  region     = var.region
  cluster_id = "${var.name_prefix}-secure"

  # --- PSC instead of PSA ---
  psc_enabled = true
  psc_allowed_consumer_projects = length(var.psc_allowed_consumer_projects) > 0 ? (
    var.psc_allowed_consumer_projects
  ) : [data.google_project.this.number]

  # --- CMEK on the cluster and on backups ---
  kms_key_name        = google_kms_crypto_key.alloydb.id
  backup_kms_key_name = google_kms_crypto_key.alloydb.id

  cpu_count         = var.cpu_count
  availability_type = "REGIONAL"

  initial_user_password = var.initial_user_password

  # --- Transport security ---
  ssl_mode = "ENCRYPTED_ONLY"

  # Reject anything that is not the Auth Proxy or a language connector. This
  # is the control that makes a stolen password insufficient on its own: the
  # caller also needs an IAM identity holding roles/alloydb.client.
  require_connectors = true

  # Public IP stays off, and no external networks are authorised.
  enable_public_ip             = false
  authorized_external_networks = []

  database_flags = {
    # --- IAM database authentication: no stored passwords ---
    "alloydb.iam_authentication"       = "on"
    "alloydb.iam_group_authentication" = "on"

    # --- pgAudit ---
    "alloydb.enable_pgaudit" = "on"
    "pgaudit.log"            = var.pgaudit_log_classes
    # Record the actual parameter values, not just the statement shape. High
    # forensic value; also means audit logs may contain sensitive data, so
    # treat the log sink as a sensitive data store.
    "pgaudit.log_parameter" = "on"
    # Attribute each audited statement to the relation it touched.
    "pgaudit.log_relation" = "on"
    # Keep audit volume manageable on repetitive statements.
    "alloydb.enable_auditlog_volume_reduction" = "on"

    # --- Protect password hashes ---
    # Without these, any authenticated user can read pg_authid / pg_shadow
    # and exfiltrate every password hash in the cluster.
    "alloydb.pg_authid_select_role" = "alloydbsuperuser"
    "alloydb.pg_shadow_select_role" = "alloydbsuperuser"

    # --- Password policy for any remaining built-in users ---
    "password.enforce_complexity"                         = "on"
    "password.min_pass_length"                            = "16"
    "password.min_uppercase_letters"                      = "1"
    "password.min_lowercase_letters"                      = "1"
    "password.min_numerical_chars"                        = "1"
    "password.min_special_chars"                          = "1"
    "password.enforce_password_does_not_contain_username" = "on"
    "password.enforce_expiration"                         = "on"
    "password.expiration_in_days"                         = "90"
    "password.notify_expiration_in_days"                  = "14"

    # --- Session hygiene ---
    "idle_in_transaction_session_timeout" = "60000"
    "statement_timeout"                   = "300000"

    # --- Logging ---
    "log_min_duration_statement" = "1000"
    "log_connections"            = "on"
    "log_disconnections"         = "on"
    "log_lock_waits"             = "on"
  }

  # Long PITR window: ransomware and malicious-insider scenarios need a
  # recovery point well before the incident was detected. 35 days is the max.
  continuous_backup_enabled              = true
  continuous_backup_recovery_window_days = 35

  automated_backup = {
    enabled         = true
    start_hour      = 2
    retention_count = 60
  }

  maintenance_window = {
    day   = "SUNDAY"
    hours = 4
  }

  deletion_protection = var.deletion_protection
  deletion_policy     = "DEFAULT"

  labels = {
    env             = "prod"
    data_class      = "confidential"
    managed_by      = "terraform"
    compliance_tier = "high"
  }

  depends_on = [
    # The key grant MUST exist before the cluster tries to use the key.
    google_kms_crypto_key_iam_member.alloydb_agent,
    module.network,
  ]
}

# ---------------------------------------------------------------------------
# 5. Consumer-side PSC endpoint and its DNS
#
# With PSC you are responsible for the endpoint and the record that resolves
# to it. This is the part people miss when they move over from PSA, so it is
# factored into a small shared module that every example in this repo uses -
# see terraform/modules/psc-endpoint.
#
# The endpoint is a regional resource. One per region, per instance.
# ---------------------------------------------------------------------------
module "psc_endpoint" {
  source = "../../modules/psc-endpoint"

  project_id = var.project_id
  region     = var.region
  name       = "${var.name_prefix}-alloydb-psc-ep"

  network_self_link = module.network.network_self_link
  subnet_self_link  = module.network.subnet_self_link

  service_attachment_link = module.alloydb.psc_service_attachment_link

  create_dns = var.create_psc_dns
  dns_name   = module.alloydb.psc_dns_name

  labels = {
    env        = "prod"
    data_class = "confidential"
  }
}

# ---------------------------------------------------------------------------
# 6. Audit logging
# ---------------------------------------------------------------------------
resource "google_project_iam_audit_config" "alloydb" {
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

# Export to a SIEM / security project. The destination deliberately lives
# outside this project's blast radius: an attacker with admin on the database
# project should not be able to delete the evidence.
resource "google_logging_project_sink" "alloydb_audit" {
  count = var.audit_sink_destination == null ? 0 : 1

  name    = "${var.name_prefix}-alloydb-audit"
  project = var.project_id

  destination = var.audit_sink_destination

  filter = <<-EOT
    protoPayload.serviceName="alloydb.googleapis.com" OR
    (resource.type="alloydb.googleapis.com/Instance" AND
     logName:"cloudaudit.googleapis.com")
  EOT

  # Creates a dedicated writer identity that must be granted write access on
  # the destination.
  unique_writer_identity = true
}

# ---------------------------------------------------------------------------
# 7. Monitoring, including the audit pipeline
# ---------------------------------------------------------------------------
module "observability" {
  source = "../../modules/observability"

  project_id = var.project_id
  cluster_id = module.alloydb.cluster_id

  alert_name_prefix = "${var.name_prefix}-secure"

  # pgAudit is on with parameter logging, so the shipping pipeline matters.
  # A silently backlogged audit pipeline is a compliance gap.
  enable_audit_backlog_alert = true

  memory_available_bytes_threshold = var.cpu_count * 8 * 1024 * 1024 * 1024 / 8

  depends_on = [module.alloydb]
}
