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
  description = "Prefix for resource names. Keep it short - it is combined with suffixes."
  type        = string
  default     = "alloydb-wk"
}

variable "subnet_cidr" {
  description = "CIDR for the application subnet."
  type        = string
  default     = "10.10.0.0/24"
}

variable "initial_user_password" {
  description = <<-EOT
    Password for the initial 'postgres' user.

    Supply this via TF_VAR_initial_user_password or a tfvars file that is NOT
    committed. It is written to Terraform state in plaintext.
  EOT
  type        = string
  sensitive   = true
}

# ---------------------------------------------------------------------------
# Private Service Connect
# ---------------------------------------------------------------------------

variable "psc_allowed_consumer_projects" {
  description = <<-EOT
    Project NUMBERS (as strings) permitted to create a PSC endpoint against
    this instance. Project numbers, not project IDs.

    Leave empty to allow only this project, which is the least-privilege
    choice. Add others deliberately: each entry is a grant of network
    reachability to the database.
  EOT
  type        = list(string)
  default     = []
}

variable "create_psc_dns" {
  description = <<-EOT
    Whether to create a private Cloud DNS zone and A record mapping the
    AlloyDB-advertised PSC hostname to the endpoint IP.

    Defaults to false because most organisations manage DNS centrally and
    would rather this configuration did not create zones underneath them.

    Something still has to create that record. The Auth Proxy and the language
    connectors resolve the hostname rather than the IP, so until the record
    exists they cannot connect. The psc_endpoint output tells you exactly which
    name to point at which address.
  EOT
  type        = bool
  default     = false
}
