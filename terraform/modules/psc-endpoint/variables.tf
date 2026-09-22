variable "project_id" {
  description = "Project that owns the consumer VPC and the endpoint."
  type        = string
}

variable "region" {
  description = <<-EOT
    Region for the endpoint.

    A PSC endpoint is a regional resource and must sit in the same region as
    the AlloyDB instance it targets. A multi-region deployment needs one
    endpoint per region - see terraform/examples/05-cross-region-dr.
  EOT
  type        = string
}

variable "name" {
  description = "Name for the address and forwarding rule. Must be unique per project and region."
  type        = string
}

variable "network_self_link" {
  description = "Self link of the consumer VPC the endpoint is created in."
  type        = string
}

variable "subnet_self_link" {
  description = "Self link of the subnet the endpoint's internal IP is allocated from."
  type        = string
}

variable "service_attachment_link" {
  description = <<-EOT
    The AlloyDB instance's PSC service attachment.

    Comes from the alloydb-cluster module's psc_service_attachment_link output.
    This is null unless the cluster was created with psc_enabled = true.
  EOT
  type        = string
}

variable "ip_address" {
  description = <<-EOT
    Optional static internal IP for the endpoint.

    Leave null to let GCP allocate one from the subnet. Set it when your
    organisation requires IPs to come from a planned range, or when a firewall
    policy elsewhere references a fixed address.
  EOT
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# DNS
# ---------------------------------------------------------------------------

variable "create_dns" {
  description = <<-EOT
    Whether to create a private DNS zone and A record for the AlloyDB-advertised
    PSC hostname.

    Defaults to false. Most organisations of any size manage DNS centrally, and
    a module that quietly creates zones tends to collide with that. Enable it
    for self-contained demos and sandboxes.

    When false, this module still outputs dns_name and ip_address so you can
    create the record wherever your DNS actually lives. Nothing resolves until
    you do - the AlloyDB connectors and the Auth Proxy expect that hostname to
    resolve, so this is a required step, not an optional nicety.
  EOT
  type        = bool
  default     = false
}

variable "dns_name" {
  description = <<-EOT
    The hostname AlloyDB advertises for the instance, from the alloydb-cluster
    module's psc_dns_name output. Arrives fully qualified with a trailing dot.

    Only needed when create_dns is true.
  EOT
  type        = string
  default     = null
}

variable "dns_ttl" {
  description = "TTL in seconds for the A record. Only used when create_dns is true."
  type        = number
  default     = 300
}

variable "labels" {
  description = "Labels applied to the reserved address."
  type        = map(string)
  default     = {}
}
