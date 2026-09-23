# ---------------------------------------------------------------------------
# Consumer-side Private Service Connect endpoint for an AlloyDB instance.
#
# With PSA, Google creates the peering and the instance gets an IP inside a
# range you allocated. With PSC, the instance publishes a *service attachment*
# and you are responsible for everything on your side of it: the endpoint, its
# IP, and the DNS that makes the advertised hostname resolve.
#
# That shift of responsibility is the single most common source of confusion
# when a team moves from PSA to PSC. The cluster can be healthy, the service
# attachment can be correct, and connections still fail - because nothing was
# ever created to connect *to*.
#
# This module covers the consumer side for one region. PSC endpoints are
# regional, so a multi-region deployment instantiates this module once per
# region.
# ---------------------------------------------------------------------------

# The endpoint's internal IP.
#
# Reserved as its own resource rather than letting the forwarding rule pick an
# ephemeral address, so the IP survives a forwarding-rule replacement. Clients
# and DNS records that cached it keep working.
resource "google_compute_address" "psc" {
  name         = var.name
  project      = var.project_id
  region       = var.region
  subnetwork   = var.subnet_self_link
  address_type = "INTERNAL"
  address      = var.ip_address

  description = "PSC endpoint IP for an AlloyDB instance."

  labels = var.labels
}

# The endpoint itself.
resource "google_compute_forwarding_rule" "psc" {
  name    = var.name
  project = var.project_id
  region  = var.region
  network = var.network_self_link

  ip_address = google_compute_address.psc.self_link
  target     = var.service_attachment_link

  # Must be the empty string for a PSC endpoint. Supplying any load balancing
  # scheme - even INTERNAL - is rejected by the API. This is easy to trip over
  # because every other forwarding rule requires one.
  load_balancing_scheme = ""
}

# ---------------------------------------------------------------------------
# Private DNS
#
# AlloyDB advertises a hostname of the form
#   <uid>.<region>.alloydb-psc.goog.
# but does not create a record for it. The Auth Proxy and the Language
# Connectors both expect that name to resolve to your endpoint, so something
# has to create the record.
#
# Disabled by default: most organisations manage DNS centrally and a module
# that creates zones underneath them causes problems. When disabled, the
# dns_name and ip_address outputs give you what you need to create the record
# wherever your DNS is actually managed.
# ---------------------------------------------------------------------------
locals {
  # The advertised name is fully qualified with a trailing dot:
  #   "<uid>.<region>.alloydb-psc.goog."
  # The managed zone covers "<region>.alloydb-psc.goog." so that one zone
  # can hold records for several instances in the same region.
  zone_dns_name = "${var.region}.alloydb-psc.goog."
}

resource "google_dns_managed_zone" "psc" {
  count = var.create_dns ? 1 : 0

  name     = var.name
  project  = var.project_id
  dns_name = local.zone_dns_name

  visibility = "private"

  private_visibility_config {
    networks {
      network_url = var.network_self_link
    }
  }

  description = "Resolves the AlloyDB PSC hostname to this VPC's endpoint IP."

  labels = var.labels
}

resource "google_dns_record_set" "psc" {
  count = var.create_dns ? 1 : 0

  project      = var.project_id
  managed_zone = google_dns_managed_zone.psc[0].name

  # Already fully qualified with a trailing dot.
  name    = var.dns_name
  type    = "A"
  ttl     = var.dns_ttl
  rrdatas = [google_compute_address.psc.address]
}

# Surfaces the misconfiguration that is otherwise only discovered at connect
# time: asking for DNS without supplying the name to create it for.
check "dns_inputs_consistent" {
  assert {
    condition     = var.create_dns ? var.dns_name != null : true
    error_message = "create_dns is true but dns_name is null. Pass the alloydb-cluster module's psc_dns_name output, which is only populated when the cluster was created with psc_enabled = true."
  }
}
