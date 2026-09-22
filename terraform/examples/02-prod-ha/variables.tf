variable "project_id" {
  description = "Google Cloud project ID."
  type        = string
}

variable "region" {
  description = "Region for the VPC, subnet and AlloyDB cluster."
  type        = string
  default     = "us-central1"
}

variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
  default     = "alloydb-wk"
}

variable "subnet_cidr" {
  description = "CIDR for the application subnet."
  type        = string
  default     = "10.20.0.0/24"
}

variable "psa_range_address" {
  description = <<-EOT
    Start address of the reserved Private Services Access range, e.g.
    "10.100.0.0". Pin it in production so it is stable and documentable.
  EOT
  type        = string
  default     = "10.100.0.0"
}

variable "cpu_count" {
  description = <<-EOT
    vCPUs for the primary instance.

    Remember a REGIONAL primary runs two VMs, so quota consumption is 2x this
    value. See the vcpu_quota_consumed output.
  EOT
  type        = number
  default     = 8
}

variable "initial_user_password" {
  description = "Password for the initial 'postgres' user. Stored in plaintext in state."
  type        = string
  sensitive   = true
}

variable "require_connectors" {
  description = <<-EOT
    Force all connections through the AlloyDB Auth Proxy or a language
    connector. This blocks plain psql/JDBC, so confirm every client and every
    operator runbook can use a connector before enabling it.
  EOT
  type        = bool
  default     = false
}

variable "app_service_account_email" {
  description = <<-EOT
    Service account the application runs as. When set, it is granted
    roles/alloydb.client and roles/alloydb.databaseUser and registered as an
    IAM database user, so the application needs no database password.

    Leave null to skip.
  EOT
  type        = string
  default     = null
}

variable "enable_data_access_logs" {
  description = <<-EOT
    Enable Data Access audit logs for the AlloyDB API.

    Required for pgAudit records to be delivered. These logs are billable and
    can be high volume - see docs/04-operations/audit-logging-and-siem.md for
    cost control.
  EOT
  type        = bool
  default     = true
}

variable "alert_email" {
  description = "Email address for alert notifications. Null creates the policies without a notification channel."
  type        = string
  default     = null
}
