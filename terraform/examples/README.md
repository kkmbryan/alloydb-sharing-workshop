# Terraform examples

Five worked deployments, in the order they are meant to be read. Each one is
self-contained: `terraform init && terraform apply` inside the directory, no
external module registry, no shared state.

| Example | What it is for |
|---|---|
| [`01-dev-minimal`](01-dev-minimal/) | The smallest sensible deployment. Read this first. |
| [`02-prod-ha`](02-prod-ha/) | The reference production build. If you copy one, copy this. |
| [`03-read-pool-scaling`](03-read-pool-scaling/) | Horizontal read scaling and workload isolation. |
| [`04-secure-cmek`](04-secure-cmek/) | The hardened build: CMEK, pgAudit, audit export. |
| [`05-cross-region-dr`](05-cross-region-dr/) | A replicated secondary in a second region. |

The examples share three local modules in [`../modules`](../modules/):
`alloydb-cluster`, `network` and `psc-endpoint`.

## Why every example uses Private Service Connect

AlloyDB offers two private connectivity models. These examples standardise on
Private Service Connect (PSC) rather than Private Services Access (PSA).

| Private Services Access | Private Service Connect |
|---|---|
| Your VPC is peered to Google's producer network | No peering. You create an endpoint in your own subnet |
| You reserve an IP range and hand it to Google, VPC-wide | Google's side consumes no address space in your VPC beyond the endpoint IP |
| Google places a private IP in your VPC for you | You own the endpoint and its DNS record |
| Reachability follows the peering | Reachability is granted explicitly, per consumer project, per instance |

For a security review the third and fourth rows are usually what settle it.
With PSC there is no peering to reason about, no transitive reachability to
trace, and access is an allow-list of consumer project numbers that can be
reviewed like any other grant. Each AlloyDB instance publishes its own service
attachment, so you can expose a read pool to one project without exposing the
primary.

The trade is real and worth stating plainly: **you take on operational work
that PSA does for you.** An endpoint is an internal address plus a forwarding
rule, and AlloyDB advertises a hostname it does not create a DNS record for.
Both are yours to manage. The
[`psc-endpoint`](../modules/psc-endpoint/) module exists so that work is
written once rather than five times.

## Three things that catch people out

**The choice is permanent.** PSA and PSC are mutually exclusive and cannot be
changed after the cluster is created. Moving between them means a new cluster
and a data migration, so decide before the first `apply`.

**Nothing resolves until you create the DNS record.** AlloyDB advertises a
hostname of the form `<uid>.<region>.alloydb-psc.goog.` but does not publish
an A record for it. The Auth Proxy and the language connectors resolve that
hostname rather than the IP, so until the record exists they cannot connect.
Every example takes a `create_psc_dns` variable, defaulting to `false` on the
assumption that DNS is managed centrally. Each one also outputs exactly which
name has to point at which address.

**Endpoints are regional, and there is one per instance.** A multi-region
deployment needs an endpoint per region ([`05-cross-region-dr`](05-cross-region-dr/)),
and a cluster with read pools needs one per pool
([`03-read-pool-scaling`](03-read-pool-scaling/)). Adding a read pool is
therefore also adding an endpoint and a DNS record.

## If your organisation uses PSA

PSA remains fully supported, and nothing here is an argument that it is
insecure. To use it, set `enable_psa = true` on the `network` module and pass
`network_self_link` plus `allocated_ip_range` to the `alloydb-cluster` module
instead of `psc_enabled`. The cluster module supports both paths; the examples
simply pick one.
