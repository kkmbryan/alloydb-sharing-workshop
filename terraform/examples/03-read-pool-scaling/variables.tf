variable "project_id" {
  description = "Google Cloud project ID."
  type        = string
}

variable "region" {
  description = "Region for all resources."
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
  default     = "10.30.0.0/24"
}

variable "primary_cpu_count" {
  description = "vCPUs for the primary and for the application read pool nodes."
  type        = number
  default     = 4
}

variable "app_pool_nodes" {
  description = <<-EOT
    Nodes in the application read pool. Counts against the 20-node
    per-cluster budget shared with every other read pool.
  EOT
  type        = number
  default     = 2
}

variable "analytics_pool_nodes" {
  description = "Nodes in the analytics read pool. Usually few and large rather than many and small."
  type        = number
  default     = 1
}

variable "analytics_cpu_count" {
  description = <<-EOT
    vCPUs per analytics read pool node.

    Larger than the app pool because analytical queries need memory for sorts
    and hash joins, and because the columnar engine claims a share of
    instance memory.
  EOT
  type        = number
  default     = 8
}

variable "replication_lag_ms_threshold" {
  description = "Replication lag alert threshold in ms. Derive it from the staleness your application tolerates."
  type        = number
  default     = 10000
}

variable "initial_user_password" {
  description = "Password for the initial 'postgres' user."
  type        = string
  sensitive   = true
}

# ---------------------------------------------------------------------------
# Private Service Connect
# ---------------------------------------------------------------------------

variable "psc_allowed_consumer_projects" {
  description = <<-EOT
    Project NUMBERS (as strings) permitted to create a PSC endpoint against
    these instances. Project numbers, not project IDs.

    Leave empty to allow only this project, which is the least-privilege
    choice. The allow-list applies to the primary and to every read pool.
  EOT
  type        = list(string)
  default     = []
}

variable "create_psc_dns" {
  description = <<-EOT
    Whether to create a private Cloud DNS zone and A record for each instance's
    PSC hostname.

    Defaults to false because most organisations manage DNS centrally. With
    read pools there is one record per instance, so this is worth planning
    rather than discovering at connect time.
  EOT
  type        = bool
  default     = false
}
