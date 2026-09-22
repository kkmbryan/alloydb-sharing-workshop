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
