variable "project_id" {
  description = "Project that owns the VPC."
  type        = string
}

variable "region" {
  description = "Region for the subnet and any PSC endpoint."
  type        = string
}

variable "name_prefix" {
  description = "Prefix for all resource names, so one config can be deployed many times."
  type        = string
}

variable "create_network" {
  description = "Create a new VPC. Set false to attach to an existing one via existing_network_name."
  type        = bool
  default     = true
}

variable "existing_network_name" {
  description = "Name of an existing VPC to use when create_network is false."
  type        = string
  default     = null
}

variable "subnet_cidr" {
  description = "CIDR for the application subnet. This is where your app VMs/GKE nodes and any PSC endpoint live."
  type        = string
  default     = "10.10.0.0/24"
}

# ---------------------------------------------------------------------------
# Private Services Access
# ---------------------------------------------------------------------------

variable "enable_psa" {
  description = <<-EOT
    Provision Private Services Access: reserve an IP range and peer it to the
    service producer network. Required for PSA-mode AlloyDB clusters.

    Not needed for PSC-mode clusters.
  EOT
  type        = bool
  default     = true
}

variable "psa_range_prefix_length" {
  description = <<-EOT
    Prefix length for the reserved PSA range. /16 is the common choice and
    leaves room for future managed services; /24 is about the practical
    minimum.

    This range is consumed by Google's producer network. It must not overlap
    anything else you peer, now or later.
  EOT
  type        = number
  default     = 16
}

variable "psa_range_address" {
  description = <<-EOT
    Optional explicit start address for the PSA range, e.g. "10.100.0.0".
    Leave null to let Google allocate. Pin it in production so the range is
    predictable and documentable in your IPAM.
  EOT
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# Egress for the Auth Proxy
# ---------------------------------------------------------------------------

variable "enable_private_google_access" {
  description = <<-EOT
    Enable Private Google Access on the subnet.

    Required if your clients have no external IP and need to reach
    googleapis.com - which the AlloyDB Auth Proxy does, to fetch ephemeral
    certificates. Without this, the proxy fails to start with a confusing
    timeout.
  EOT
  type        = bool
  default     = true
}
