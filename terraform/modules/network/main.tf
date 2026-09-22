# ===========================================================================
# VPC + subnet + (optionally) Private Services Access for AlloyDB
#
# PSA in three resources:
#   1. google_compute_global_address  - reserve a block YOU own for Google's
#                                       producer network to allocate from
#   2. google_service_networking_connection - peer your VPC to that network
#   3. the AlloyDB cluster references the VPC and (optionally) the range name
# ===========================================================================

locals {
  network_name      = var.create_network ? google_compute_network.this[0].name : var.existing_network_name
  network_self_link = var.create_network ? google_compute_network.this[0].id : data.google_compute_network.existing[0].id
}

data "google_compute_network" "existing" {
  count   = var.create_network ? 0 : 1
  name    = var.existing_network_name
  project = var.project_id
}

resource "google_compute_network" "this" {
  count = var.create_network ? 1 : 0

  name    = "${var.name_prefix}-vpc"
  project = var.project_id

  # Always use custom subnets. Auto-mode creates a subnet in every region with
  # fixed ranges, which reliably collides with on-prem or other clouds later.
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "app" {
  name          = "${var.name_prefix}-${var.region}-app"
  project       = var.project_id
  region        = var.region
  network       = local.network_self_link
  ip_cidr_range = var.subnet_cidr

  # Lets private-only clients reach googleapis.com. The AlloyDB Auth Proxy
  # needs this to fetch ephemeral certificates.
  private_ip_google_access = var.enable_private_google_access

  log_config {
    # VPC Flow Logs. Sampling at 0.5 keeps cost sane while preserving enough
    # detail for a security investigation. Raise to 1.0 for a sensitive
    # environment.
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# ---------------------------------------------------------------------------
# PSA: reserve the range
# ---------------------------------------------------------------------------
resource "google_compute_global_address" "psa_range" {
  count = var.enable_psa ? 1 : 0

  name    = "${var.name_prefix}-psa-range"
  project = var.project_id
  network = local.network_self_link

  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = var.psa_range_prefix_length
  address       = var.psa_range_address

  description = "Reserved for Private Services Access (AlloyDB and other Google managed services)."
}

# ---------------------------------------------------------------------------
# PSA: peer to the service producer network
# ---------------------------------------------------------------------------
resource "google_service_networking_connection" "psa" {
  count = var.enable_psa ? 1 : 0

  network = local.network_self_link
  service = "servicenetworking.googleapis.com"

  # NAME of the global address, not its id.
  reserved_peering_ranges = [google_compute_global_address.psa_range[0].name]

  # ABANDON leaves the peering in place on destroy instead of trying to remove
  # it. Deleting a service networking connection is the single most common way
  # for a `terraform destroy` of a database stack to hang or fail, because the
  # producer side still holds resources. Abandoning is the pragmatic default.
  deletion_policy = "ABANDON"

  # Recover automatically if a stale peering already exists on this VPC from a
  # previous, partially torn down deployment.
  update_on_creation_fail = true
}

# ---------------------------------------------------------------------------
# Firewall: allow PostgreSQL only from inside the subnet
#
# Note: traffic to an AlloyDB instance over PSA traverses the peering and is
# not filtered by your VPC firewall rules in the way VM-to-VM traffic is. This
# rule governs traffic between your own workloads (for example an app talking
# to an Auth Proxy sidecar).
# ---------------------------------------------------------------------------
resource "google_compute_firewall" "allow_postgres_internal" {
  name    = "${var.name_prefix}-allow-postgres-internal"
  project = var.project_id
  network = local.network_self_link

  description = "Allow PostgreSQL and pooled connections between workloads inside the app subnet."
  direction   = "INGRESS"
  priority    = 1000

  source_ranges = [var.subnet_cidr]

  allow {
    protocol = "tcp"
    ports = [
      "5432", # PostgreSQL / AlloyDB Auth Proxy listener
      "6432", # AlloyDB Managed Connection Pooling
    ]
  }
}

# ---------------------------------------------------------------------------
# Explicit deny-all ingress, logged.
#
# GCP already denies ingress implicitly at priority 65535, but that implicit
# rule cannot log. An explicit low-priority deny at 65534 gives you a record of
# what was rejected, which is what a security team actually wants.
# ---------------------------------------------------------------------------
resource "google_compute_firewall" "deny_all_ingress_logged" {
  name    = "${var.name_prefix}-deny-all-ingress-logged"
  project = var.project_id
  network = local.network_self_link

  description = "Explicit logged deny-all, so rejected ingress is visible in Cloud Logging."
  direction   = "INGRESS"
  priority    = 65534

  source_ranges = ["0.0.0.0/0"]

  deny {
    protocol = "all"
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}
