variable "project_id" {
  description = "Google Cloud project ID."
  type        = string
}

variable "primary_region" {
  description = "Region hosting the primary cluster."
  type        = string
  default     = "us-central1"
}

variable "secondary_region" {
  description = <<-EOT
    Region hosting the DR secondary cluster.

    Choose a region far enough away to be independent of the primary's failure
    domains, but close enough that replication lag and inter-region egress
    stay acceptable. Also confirm it satisfies any data residency obligations.
  EOT
  type        = string
  default     = "us-east4"
}

variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
  default     = "alloydb-dr"
}

variable "primary_subnet_cidr" {
  description = "CIDR for the subnet in the primary region."
  type        = string
  default     = "10.50.0.0/24"
}

variable "secondary_subnet_cidr" {
  description = "CIDR for the subnet in the secondary region. Must not overlap the primary."
  type        = string
  default     = "10.51.0.0/24"
}

variable "cpu_count" {
  description = <<-EOT
    vCPUs, applied to BOTH the primary and the secondary.

    Deliberately a single variable: an undersized secondary increases your RPO
    and leaves you short of capacity after a failover. Keep them matched.

    Quota note: both clusters are REGIONAL, so each consumes 2x this value in
    its own region's vCPU quota.
  EOT
  type        = number
  default     = 4
}

variable "dr_replication_lag_ms_threshold" {
  description = <<-EOT
    Alert threshold for cross-region replication lag, in milliseconds.

    This value IS your recovery point objective under an unplanned regional
    failover. Set it to the maximum data loss the business has agreed to
    tolerate, not to whatever the graph happens to show today.
  EOT
  type        = number
  default     = 60000
}

variable "initial_user_password" {
  description = "Password for the initial 'postgres' user on the primary cluster."
  type        = string
  sensitive   = true
}
