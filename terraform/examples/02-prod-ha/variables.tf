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

variable "psc_allowed_consumer_projects" {
  description = <<-EOT
    Project NUMBERS (as strings) permitted to create a PSC endpoint against
    this instance. Project numbers, not project IDs.

    Leave empty to allow only this project, which is the least-privilege
    choice. Each additional entry is a grant of network reachability to the
    database, so add them deliberately and review them like any other access
    grant.
  EOT
  type        = list(string)
  default     = []
}

variable "psc_endpoint_ip" {
  description = <<-EOT
    Static internal IP for the PSC endpoint, from within subnet_cidr.

    Pin it in production so firewall rules, IPAM records and runbooks can
    reference a stable address. Leave null to let GCP pick one.
  EOT
  type        = string
  default     = null
}

variable "create_psc_dns" {
  description = <<-EOT
    Whether to create a private Cloud DNS zone and A record mapping the
    AlloyDB-advertised PSC hostname to the endpoint IP.

    Defaults to false because most organisations manage DNS centrally and
    would rather this configuration did not create zones underneath them.

    Something still has to create that record. The Auth Proxy and the language
    connectors resolve the hostname rather than the IP, so until the record
    exists they cannot connect. The psc_endpoint_summary output tells you which
    name to point at which address.
  EOT
  type        = bool
  default     = false
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
