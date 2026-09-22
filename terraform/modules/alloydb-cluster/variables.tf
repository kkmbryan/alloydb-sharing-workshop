# ===========================================================================
# Required
# ===========================================================================

variable "cluster_id" {
  description = "Name of the AlloyDB cluster. Must be unique within the project and region."
  type        = string
}

variable "region" {
  description = "Region for the cluster, e.g. us-central1. AlloyDB storage is regional."
  type        = string
}

variable "project_id" {
  description = "Project that will own the cluster."
  type        = string
}

# ===========================================================================
# Networking - choose EXACTLY ONE of PSA or PSC
#
# This is an architectural decision that CANNOT be changed after the cluster
# is created. See docs/04-operations/security-hardening.md.
# ===========================================================================

variable "network_self_link" {
  description = <<-EOT
    PSA path: self_link / id of the VPC the cluster attaches to via Private
    Services Access. Leave null to use Private Service Connect instead.
    Mutually exclusive with psc_enabled.
  EOT
  type        = string
  default     = null
}

variable "allocated_ip_range" {
  description = <<-EOT
    PSA path: NAME (not id) of the google_compute_global_address reserved for
    Private Services Access. Optional - if null, Google picks from any range
    allocated to servicenetworking on this VPC.
  EOT
  type        = string
  default     = null
}

variable "psc_enabled" {
  description = <<-EOT
    PSC path: create the cluster for Private Service Connect instead of PSA.
    The consumer is then responsible for creating the PSC endpoint AND the
    DNS record. Mutually exclusive with network_self_link. ForceNew.
  EOT
  type        = bool
  default     = false
}

variable "psc_allowed_consumer_projects" {
  description = <<-EOT
    PSC path: project NUMBERS (as strings) permitted to create a PSC endpoint
    against this instance's service attachment. Project numbers, not IDs.
  EOT
  type        = list(string)
  default     = []
}

# ===========================================================================
# Primary instance
# ===========================================================================

variable "primary_instance_id" {
  description = "Name of the primary instance."
  type        = string
  default     = null
}

variable "cpu_count" {
  description = <<-EOT
    vCPUs for the primary instance.

    QUOTA NOTE: a primary instance consumes TWO VMs worth of vCPU quota when
    availability_type is REGIONAL (active + standby). Budget accordingly - see
    docs/04-operations/sizing-guide.md.
  EOT
  type        = number
  default     = 2
}

variable "machine_type" {
  description = <<-EOT
    Optional explicit machine type, e.g. "n2-highmem-4" or "c4a-highmem-4-lssd".
    Leave null to let AlloyDB derive the shape from cpu_count. If both are set
    the vCPU counts must agree.
  EOT
  type        = string
  default     = null
}

variable "availability_type" {
  description = <<-EOT
    REGIONAL = HA, an active node plus a standby in another zone of the region.
    ZONAL    = single node, no automatic failover.

    Only REGIONAL instances are covered by the AlloyDB HA SLA. Use ZONAL for
    dev/test only.
  EOT
  type        = string
  default     = "REGIONAL"

  validation {
    condition     = contains(["REGIONAL", "ZONAL"], var.availability_type)
    error_message = "availability_type must be REGIONAL or ZONAL."
  }
}

variable "database_flags" {
  description = <<-EOT
    PostgreSQL / AlloyDB flags for the primary instance. Values must be strings.

    Some flags require an instance restart (which drops connections) - see
    config/database-flags/ for curated baselines and the restart column.
  EOT
  type        = map(string)
  default     = {}
}

# ===========================================================================
# Read pool
# ===========================================================================

variable "read_pool_instances" {
  description = <<-EOT
    Read pool instances to create, keyed by instance_id.

    Budget: a maximum of 20 read pool NODES per cluster, summed across all
    read pool instances.

    CONSTRAINT: if you set max_connections on a read pool, the value must be
    greater than or equal to the primary's max_connections.
  EOT
  type = map(object({
    node_count     = number
    cpu_count      = optional(number)
    machine_type   = optional(string)
    database_flags = optional(map(string), {})
  }))
  default = {}
}

# ===========================================================================
# Security
# ===========================================================================

variable "initial_user_password" {
  description = <<-EOT
    Password for the initial 'postgres' user.

    WARNING: this value is stored in PLAINTEXT in Terraform state. Use a
    secret manager and a remote backend with encryption and tight IAM, or
    prefer IAM database authentication and rotate this password out of band.
  EOT
  type        = string
  default     = null
  sensitive   = true
}

variable "kms_key_name" {
  description = <<-EOT
    CMEK key for the cluster, e.g.
    projects/P/locations/L/keyRings/R/cryptoKeys/K

    The key must be in the SAME region as the cluster, and the AlloyDB service
    agent needs roles/cloudkms.cryptoKeyEncrypterDecrypter on it BEFORE the
    cluster is created.

    ForceNew: CMEK cannot be added to an existing cluster in place.
  EOT
  type        = string
  default     = null
}

variable "backup_kms_key_name" {
  description = <<-EOT
    Optional separate CMEK key for automated and continuous backups. Defaults
    to kms_key_name when null. Backups carry their own encryption_config, so
    the service agent needs a grant on this key too.
  EOT
  type        = string
  default     = null
}

variable "enable_public_ip" {
  description = <<-EOT
    Assign an inbound public IP to the primary instance.

    Leave false. A public IP on a database is a finding in most security
    reviews; use PSA/PSC plus the AlloyDB Auth Proxy instead.
  EOT
  type        = bool
  default     = false
}

variable "authorized_external_networks" {
  description = <<-EOT
    CIDR allow-list for direct public-IP connections. Only valid when
    enable_public_ip is true - leaving entries here while disabling public IP
    is an API error.
  EOT
  type        = list(string)
  default     = []
}

variable "ssl_mode" {
  description = <<-EOT
    ENCRYPTED_ONLY                 - reject unencrypted connections (recommended)
    ALLOW_UNENCRYPTED_AND_ENCRYPTED - permissive
  EOT
  type        = string
  default     = "ENCRYPTED_ONLY"

  validation {
    condition     = contains(["ENCRYPTED_ONLY", "ALLOW_UNENCRYPTED_AND_ENCRYPTED"], var.ssl_mode)
    error_message = "ssl_mode must be ENCRYPTED_ONLY or ALLOW_UNENCRYPTED_AND_ENCRYPTED."
  }
}

variable "require_connectors" {
  description = <<-EOT
    Force all connections through the AlloyDB Auth Proxy or a language
    connector.

    Strongest control, but it BREAKS plain psql/JDBC connections - every
    client and every operator workflow must run a connector. Decide this
    deliberately rather than by default.
  EOT
  type        = bool
  default     = false
}

# ===========================================================================
# Backup and recovery
# ===========================================================================

variable "automated_backup" {
  description = <<-EOT
    Automated (scheduled) backup policy. Set to null to disable scheduled
    backups - continuous backup / PITR is configured separately below.

    retention_count and retention_period_days are mutually exclusive; set
    exactly one.
  EOT
  type = object({
    enabled               = optional(bool, true)
    days_of_week          = optional(list(string), ["MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY", "SUNDAY"])
    start_hour            = optional(number, 3)
    backup_window_seconds = optional(number, 3600)
    retention_count       = optional(number, 14)
    retention_period_days = optional(number)
  })
  default = {}

  validation {
    condition = var.automated_backup == null ? true : !(
      try(var.automated_backup.retention_count, null) != null &&
      try(var.automated_backup.retention_period_days, null) != null
    )
    error_message = "Set only one of retention_count or retention_period_days, not both."
  }
}

variable "continuous_backup_enabled" {
  description = "Enable continuous backup, which is what makes point-in-time recovery possible."
  type        = bool
  default     = true
}

variable "continuous_backup_recovery_window_days" {
  description = "PITR recovery window in days. Valid range is 1-35."
  type        = number
  default     = 14

  validation {
    condition     = var.continuous_backup_recovery_window_days >= 1 && var.continuous_backup_recovery_window_days <= 35
    error_message = "continuous_backup_recovery_window_days must be between 1 and 35."
  }
}

# ===========================================================================
# Maintenance
# ===========================================================================

variable "maintenance_window" {
  description = <<-EOT
    Preferred maintenance window. Maintenance starts within one hour of this
    time. Set to null to let Google choose.

    Only whole hours are supported - the API accepts only 0 for minutes,
    seconds and nanos.
  EOT
  type = object({
    day   = string
    hours = number
  })
  default = null
}

# ===========================================================================
# Managed Connection Pooling
# ===========================================================================

variable "connection_pool" {
  description = <<-EOT
    AlloyDB Managed Connection Pooling for the primary instance.

    flags: drop the "connection-pooling-" prefix and replace dashes with
    underscores, e.g. the CLI flag --connection-pooling-pool-mode becomes
    the key "pool_mode".

    Transaction pool mode breaks session-scoped state: SET outside a
    transaction, session advisory locks, LISTEN/NOTIFY, WITH HOLD cursors and
    temp tables. Audit the application before enabling it.
  EOT
  type = object({
    enabled = bool
    flags   = optional(map(string), {})
  })
  default = null
}

# ===========================================================================
# Lifecycle
# ===========================================================================

variable "deletion_protection" {
  description = <<-EOT
    Provider-side guard. While true, terraform destroy fails. To tear down you
    must set this false and APPLY that change first, then destroy.
  EOT
  type        = bool
  default     = true
}

variable "deletion_policy" {
  description = <<-EOT
    DEFAULT - deleting a cluster that still has instances fails.
    FORCE   - delete the cluster together with its instances. Required to
              destroy a SECONDARY cluster, whose instance cannot be deleted
              independently.
  EOT
  type        = string
  default     = "DEFAULT"

  validation {
    condition     = contains(["DEFAULT", "FORCE"], var.deletion_policy)
    error_message = "deletion_policy must be DEFAULT or FORCE."
  }
}

# ===========================================================================
# Cross-region replication
# ===========================================================================

variable "cluster_type" {
  description = "PRIMARY, or SECONDARY for a cross-region replica cluster."
  type        = string
  default     = "PRIMARY"

  validation {
    condition     = contains(["PRIMARY", "SECONDARY"], var.cluster_type)
    error_message = "cluster_type must be PRIMARY or SECONDARY."
  }
}

variable "primary_cluster_name" {
  description = <<-EOT
    Required when cluster_type is SECONDARY. Full resource name of the primary:
    projects/P/locations/L/clusters/C
  EOT
  type        = string
  default     = null
}

# ===========================================================================
# Misc
# ===========================================================================

variable "database_version" {
  description = "POSTGRES_14 through POSTGRES_18. Null lets AlloyDB pick the current default."
  type        = string
  default     = null
}

variable "labels" {
  description = "Labels applied to the cluster and its instances."
  type        = map(string)
  default     = {}
}

variable "query_insights" {
  description = <<-EOT
    Query Insights configuration for the primary instance.

    query_plans_per_minute of 0 disables plan sampling. Raising
    query_string_length requires an instance restart.
  EOT
  type = object({
    query_string_length     = optional(number, 1024)
    record_application_tags = optional(bool, true)
    record_client_address   = optional(bool, true)
    query_plans_per_minute  = optional(number, 5)
  })
  default = {}
}
