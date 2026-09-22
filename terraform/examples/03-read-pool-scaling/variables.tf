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
