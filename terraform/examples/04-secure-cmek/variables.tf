variable "project_id" {
  description = "Google Cloud project ID."
  type        = string
}

variable "region" {
  description = "Region for all resources. The KMS key ring must share this region."
  type        = string
  default     = "us-central1"
}

variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
  default     = "alloydb-sec"
}

variable "subnet_cidr" {
  description = "CIDR for the subnet hosting clients and the PSC endpoint."
  type        = string
  default     = "10.40.0.0/24"
}

variable "cpu_count" {
  description = "vCPUs for the primary. A REGIONAL primary consumes 2x this in vCPU quota."
  type        = number
  default     = 4
}

variable "initial_user_password" {
  description = <<-EOT
    Password for the initial 'postgres' user.

    Even here it cannot be avoided at creation time. The intended posture is:
    create it, store it in Secret Manager as a break-glass credential, and use
    IAM database authentication for all normal access.
  EOT
  type        = string
  sensitive   = true
}

# ---------------------------------------------------------------------------
# KMS
# ---------------------------------------------------------------------------

variable "kms_protection_level" {
  description = <<-EOT
    SOFTWARE or HSM.

    HSM gives FIPS 140-2 Level 3 backing and costs more. Use HSM where a
    compliance regime requires hardware-backed key custody.
  EOT
  type        = string
  default     = "HSM"

  validation {
    condition     = contains(["SOFTWARE", "HSM"], var.kms_protection_level)
    error_message = "kms_protection_level must be SOFTWARE or HSM."
  }
}

variable "key_rotation_period" {
  description = <<-EOT
    Automatic key rotation period as a duration string. 7776000s is 90 days.

    Rotation creates a new key version for new writes; existing data remains
    readable through the version that encrypted it.
  EOT
  type        = string
  default     = "7776000s"
}

# ---------------------------------------------------------------------------
# PSC
# ---------------------------------------------------------------------------

variable "psc_allowed_consumer_projects" {
  description = <<-EOT
    Project NUMBERS (as strings) permitted to create a PSC endpoint against
    this instance. Project numbers, not project IDs.

    Empty defaults to this project only, which is the least-privilege choice.
    Add other projects explicitly and deliberately - each entry is a grant of
    network reachability to the database.
  EOT
  type        = list(string)
  default     = []
}

variable "create_psc_dns" {
  description = <<-EOT
    Whether to create the private Cloud DNS zone and A record mapping the
    AlloyDB PSC hostname to the endpoint IP.

    Defaults to false because most organisations manage DNS centrally and
    would rather this configuration did not create zones underneath them.

    Something still has to create that record. The Auth Proxy and the language
    connectors resolve the hostname rather than the IP, so until it exists they
    cannot connect. The psc_endpoint_summary output tells you which name to
    point at which address.
  EOT
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Audit
# ---------------------------------------------------------------------------

variable "pgaudit_log_classes" {
  description = <<-EOT
    Value of the pgaudit.log flag.

    Allowed: read, write, function, role, ddl, misc, misc_set, all, none,
    and subtractive forms prefixed with '-' such as '-misc'.
    Combine with commas, e.g. "all,-misc".

    "ddl,role,write" captures schema changes, privilege changes and data
    modification without the very high volume of logging every SELECT.
    Measure your log volume before moving to "all".
  EOT
  type        = string
  default     = "ddl,role,write"
}

variable "audit_sink_destination" {
  description = <<-EOT
    Destination for the audit log sink, in Cloud Logging sink format:

      pubsub.googleapis.com/projects/SEC_PROJECT/topics/TOPIC
      bigquery.googleapis.com/projects/SEC_PROJECT/datasets/DATASET
      storage.googleapis.com/BUCKET_NAME

    Put this in a separate security project so that compromise of the database
    project does not permit destroying the audit trail.

    After apply, grant the sink's writer identity write access on the
    destination - see the writer_identity output.
  EOT
  type        = string
  default     = null
}

variable "deletion_protection" {
  description = "Whether to prevent Terraform from destroying the cluster. Set false before running destroy."
  type        = bool
  default     = true
}

