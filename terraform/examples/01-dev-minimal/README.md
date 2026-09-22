# 01 — Dev / Minimal

## Purpose

This is the smallest AlloyDB deployment that still works end to end, and it is the
one to read first. It exists to teach three things: that AlloyDB needs
**private connectivity wired up before the cluster can be created** — here Private
Service Connect, with an endpoint you create in your own subnet — that a
**cluster and an instance are separate objects** with separate lifecycles, and that a
single `ZONAL` instance is the cheapest way to get a working database for a sandbox.
Use it for workshops, throwaway experiments, and for proving out network plumbing in a
new project. It is not suitable for anything anyone depends on: there is no standby
node, no alerting, and no deletion protection.

If your organisation is on Private Services Access, nothing here says PSA is wrong. It
remains fully supported; these examples simply standardise on PSC. The PSA path is the
`network_self_link` and `allocated_ip_range` variables on the cluster module, used
instead of `psc_enabled`. Decide before the first apply: the two are mutually exclusive
and cannot be changed after the cluster is created, so moving between them means a new
cluster and a data migration.

> [!CAUTION]
> A `ZONAL` instance has a single serving node with no automatic failover, and it is
> not covered by the AlloyDB HA SLA. Losing the zone loses the database's availability
> until Google or you rebuild it. For anything production-shaped, go to
> [`02-prod-ha`](../02-prod-ha/README.md).

---

## What it creates

| Resource | Terraform address | Purpose |
| --- | --- | --- |
| VPC | `module.network.google_compute_network.this` | Custom-mode VPC (`<prefix>-vpc`). Auto-mode is deliberately avoided because its fixed per-region ranges collide with on-prem later. |
| Subnet | `module.network.google_compute_subnetwork.app` | `<prefix>-<region>-app`, carries client workloads. Private Google Access on, VPC Flow Logs at 0.5 sampling. |
| PSC endpoint address | `module.psc_endpoint.google_compute_address.psc` | Internal IP (`<prefix>-dev-psc`) allocated from the app subnet. This is the address clients connect to. |
| PSC endpoint forwarding rule | `module.psc_endpoint.google_compute_forwarding_rule.psc` | The endpoint itself, targeting the instance's service attachment. `load_balancing_scheme` is the empty string — any other value is rejected by the API. |
| Private DNS zone and A record | `module.psc_endpoint.google_dns_managed_zone.psc`, `module.psc_endpoint.google_dns_record_set.psc` | *Conditional on `create_psc_dns` (default `false`).* Maps the hostname AlloyDB advertises to the endpoint IP. When off, that record is yours to create elsewhere. |
| Firewall: allow Postgres | `module.network.google_compute_firewall.allow_postgres_internal` | TCP 5432 and 6432 within the subnet CIDR — 5432 for direct connections, 6432 for the managed pooler. |
| Firewall: logged deny-all | `module.network.google_compute_firewall.deny_all_ingress_logged` | Priority 65534 explicit deny so rejected ingress is *visible* in Cloud Logging. The implicit deny at 65535 cannot log. |
| AlloyDB cluster | `module.alloydb.google_alloydb_cluster.this` | `<prefix>-dev`. Owns storage, backups, encryption, and the PSC configuration. |
| AlloyDB primary instance | `module.alloydb.google_alloydb_instance.primary` | `<prefix>-dev-primary`. Owns compute, flags, and the service attachment clients reach it through. 2 vCPU, `ZONAL`, Managed Connection Pooling enabled in session mode. |

Outputs: `cluster_name`, `psc_endpoint_ip`, `psc_dns_name`, `psc_service_attachment`,
`vcpu_quota_consumed`, `psc_endpoint_summary`, `connect_via_auth_proxy`.

There is no `primary_ip_address` output. On the PSC path the instance has no IP inside
your VPC — the endpoint you created does.

> [!NOTE]
> The cluster/instance split is the single most important AlloyDB concept. Storage is
> **regional and disaggregated** — it lives with the cluster, not on a disk attached to
> the instance. That is why resizing compute never touches your data, and why there is
> no "disk full" condition in the Cloud SQL sense. Storage grows elastically; what you
> can run out of is the per-cluster storage *quota*.

---

## Architecture diagram

```mermaid
flowchart LR
  subgraph consumer["Your VPC (prefix-vpc)"]
    subnet["Subnet prefix-region-app<br/>10.10.0.0/24<br/>Private Google Access ON"]
    client["Client / VM running<br/>alloydb-auth-proxy --psc"]
    endpoint["PSC endpoint prefix-dev-psc<br/>internal address + forwarding rule"]
    dns["A record: uid.region.alloydb-psc.goog.<br/>yours to create"]
    subnet --- client
    subnet --- endpoint
    dns -.->|"resolves to the endpoint IP"| endpoint
  end

  subgraph producer["Google producer network (no VPC peering)"]
    attachment["Service attachment<br/>published by the instance"]
    cluster["AlloyDB cluster<br/>prefix-dev<br/>regional disaggregated storage"]
    primary["Primary instance<br/>prefix-dev-primary<br/>2 vCPU, ZONAL, single node"]
    pooler["Managed Connection Pooling<br/>port 6432, session mode"]
    cluster --- primary
    primary --- attachment
    primary --- pooler
  end

  endpoint -->|"Private Service Connect"| attachment
  client -->|"TCP 5432, direct, ENCRYPTED_ONLY"| endpoint
  client -->|"TCP 6432, pooled"| endpoint

  backup["Automated backups Mon/Wed/Fri 03:00<br/>keep 3 + continuous backup, 1-day PITR"]
  cluster --> backup
```

---

## Prerequisites

### APIs

```bash
# Enable once per project. Terraform in this example does NOT enable them for you.
gcloud services enable \
  alloydb.googleapis.com \
  compute.googleapis.com \
  --project=YOUR_PROJECT_ID

# Only if you set create_psc_dns = true, so the module can manage the private zone:
gcloud services enable dns.googleapis.com --project=YOUR_PROJECT_ID
```

`servicenetworking.googleapis.com` is not in that list. It is the Private Services Access
API, and this example does not use PSA.

### IAM for whoever runs Terraform

These are the predefined roles this example's resources require. Confirm them against
your own org policy — this is the minimum set the code needs, not a Google-published
list.

| Role | Needed for |
| --- | --- |
| `roles/alloydb.admin` | Create the cluster and instance |
| `roles/compute.networkAdmin` | VPC, subnet, firewall rules, and the PSC endpoint's internal address and forwarding rule |
| `roles/dns.admin` | Only when `create_psc_dns = true`: the private zone and the A record |

### Quota to check first

| Quota | Default | Max supported | This example uses |
| --- | --- | --- | --- |
| Clusters per project per region | 3–10 (depends on project history) | 20 | 1 |
| vCPUs per project per region | 10,000 | — | **2** |
| Storage per cluster | 16 TiB | 128 TiB | negligible |

Source: [AlloyDB quotas and limits](https://cloud.google.com/alloydb/quotas).

> [!IMPORTANT]
> A **`REGIONAL`** primary instance consumes **two VMs** worth of vCPU quota — the
> active node plus the standby. This example is `ZONAL`, so it consumes **1× its vCPU
> count = 2 vCPUs**. That halving is the whole reason `ZONAL` is used here. Every other
> example in this repo is `REGIONAL` and therefore doubles. The
> `vcpu_quota_consumed` output does the arithmetic for you.

Check what you have before applying:

```bash
gcloud alloydb operations list --region=us-central1 --project=YOUR_PROJECT_ID
# Quota errors surface as: VCPUsUsedPerProjectPerRegion or ClustersUsedPerProjectPerRegion
```

---

## Usage

```bash
cd terraform/examples/01-dev-minimal

# 1. Supply variables. terraform.tfvars is gitignored.
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars          # set project_id at minimum

# 2. Prefer keeping the password out of any file on disk.
export TF_VAR_initial_user_password="$(openssl rand -base64 24)"

# 3. Standard cycle.
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

Expect roughly 10–15 minutes end to end; cluster and instance creation dominate, and the
PSC endpoint is quick by comparison. That is an observed range for this repo, not a
Google-published figure.

> [!WARNING]
> `initial_user_password` is written to Terraform state **in plaintext**. Use a remote
> backend with encryption and tight IAM, or treat this state file as a secret. The
> module sets `lifecycle.ignore_changes = [initial_user]` so changing the variable later
> will *not* rotate the password — rotate it with `ALTER ROLE` instead.

---

## Key configuration decisions explained

### Why `availability_type = "ZONAL"`

`ZONAL` provisions exactly one serving node. `REGIONAL` provisions an active node plus a
standby in a different zone of the same region, both reading the same regional storage —
which is why AlloyDB failover does not involve copying data. For a dev sandbox, the
standby buys you nothing you will actually use, and it costs you a second VM of vCPU
quota and a second VM of compute spend. The trade is explicit: no automatic failover and
no HA SLA coverage. That is a reasonable trade in a sandbox, and only in a sandbox.

### Why the PSC endpoint is a separate module

Private Service Connect is two-sided. The producer side is the cluster: `psc_enabled =
true` makes each instance publish a **service attachment**, and
`psc_allowed_consumer_projects` decides who may point at it. The consumer side is yours:
an internal `google_compute_address` and a `google_compute_forwarding_rule` in your own
subnet, targeting that attachment. Note what is *not* in `main.tf` — there is no
`network_self_link` on the cluster, because on this path the cluster is not attached to
your VPC at all.

Two details in the module are easy to trip over. The forwarding rule's
`load_balancing_scheme` must be the **empty string**; supplying any scheme, even
`INTERNAL`, is rejected, which is surprising because every other forwarding rule requires
one. And `psc_allowed_consumer_projects` takes project **numbers**, not project IDs —
`main.tf` looks this project's number up with a `data "google_project"` block so you do
not have to paste it in.

The explicit `depends_on = [module.network]` is still there, and it is still doing work:
the subnet has to exist before the cluster is created and before the endpoint's address
can be allocated from it, and Terraform cannot always infer that ordering from the
references alone.

Be clear-eyed about what PSC costs you operationally. With PSA, Google places a private
IP in your VPC and you are finished. With PSC **you own the endpoint and you own the DNS
record**, in every project and every region where clients live. That is genuine extra
work, and it is the trade for not peering your VPC to Google's producer network: no
transitive reachability to reason about, and access granted explicitly per consumer
project rather than following a peering.

### Why nothing connects until the DNS record exists

AlloyDB advertises a hostname of the form `<uid>.<region>.alloydb-psc.goog.` — note the
trailing dot — but it does **not** create a record for it. The AlloyDB Auth Proxy and the
language connectors resolve that hostname rather than the endpoint IP, so until something
creates the A record they cannot connect, whatever the endpoint's state says.

`create_psc_dns` defaults to `false` here, on the assumption that DNS is managed
centrally and that a module quietly creating zones underneath a central team causes more
problems than it solves. Set it to `true` for a self-contained sandbox and the module
creates a private zone and the record for you. Either way the
`psc_endpoint_summary` and `connect_via_auth_proxy` outputs tell you exactly which name
has to point at which address.

One more property to plan around: **a PSC endpoint is a regional resource**. It must sit
in the same region as the instance it targets, so a multi-region deployment needs one per
region — see [`05-cross-region-dr`](../05-cross-region-dr/README.md).

### Why `ssl_mode = "ENCRYPTED_ONLY"` even in dev

The only other legal value is `ALLOW_UNENCRYPTED_AND_ENCRYPTED`. There is no scenario in
which allowing plaintext database traffic is a reasonable default, and the cost of
enforcing encryption is zero. Getting into the habit in dev means the production config
is not the first time anyone tests it. Those two strings are the complete set of allowed
values in the provider schema.

### Why `require_connectors = false`

Setting this to `true` forbids direct connections entirely — every client must come
through the AlloyDB Auth Proxy or a language connector. That is the stronger control and
it is what [`04-secure-cmek`](../04-secure-cmek/README.md) does. It is off here
purely so workshop attendees can reach the database with plain `psql` without extra
setup. Treat this as a workshop affordance, not a recommendation.

### Why these two database flags

| Flag | Value | Reasoning |
| --- | --- | --- |
| `idle_in_transaction_session_timeout` | `300000` (5 min, ms) | Sessions idle *inside* a transaction hold locks and pin the vacuum horizon. In a dev environment they are almost always an abandoned `psql` window. Killing them is free. No restart required. |
| `log_min_duration_statement` | `1000` (1 s, ms) | Anything slower than a second lands in Cloud Logging, so attendees can actually see slow queries during the session. No restart required. |

Both flags are confirmed settable on AlloyDB with no instance restart. Two flags that
look tempting but are not available: `shared_preload_libraries` and `wal_level` are not
settable on AlloyDB, and the Admin API rejects them rather than warning you.

### Why Managed Connection Pooling is on, in session mode

AlloyDB ships a connection pooler inside the managed instance. It is **disabled by
default**, so the `connection_pool` block in `main.tf` is what turns it on. It is enabled
here even in a sandbox for one reason: it is the pooling story this repository
recommends, and it is worth attendees seeing it working before they meet it in a
production template. There is no separate pooler fleet to run, patch, or give its own
credential store.

| Property | Value here | Worth knowing |
| --- | --- | --- |
| Enabled | `true` | Disabled by default on every AlloyDB instance. |
| Port | `6432` | Direct, unpooled connections stay on `5432`. |
| `pool_mode` | `session` | Transaction mode is the better production default; see below. |
| Flag key style | `pool_mode` | Terraform keys drop the `connection-pooling-` CLI prefix and use underscores, so `--connection-pooling-pool-mode` becomes `pool_mode`. |

Session mode is used here rather than transaction mode because transaction pooling does
not support a set of session-scoped features that a workshop attendee poking around with
`psql` would reasonably expect: `SET`/`RESET`, `LISTEN`, `WITH HOLD CURSOR`,
`PREPARE`/`DEALLOCATE`, `PRESERVE`/`DELETE ROW` temp tables, `LOAD`, session-level
advisory locks, and protocol-level prepared plans. Session mode keeps all of those
working while still sharing server connections.
[`02-prod-ha`](../02-prod-ha/README.md) uses transaction mode, which is where the large
multiplexing win lives.

> [!NOTE]
> Managed Connection Pooling is **not supported on public IP connections**. For a
> security review that reads as an advantage rather than a limitation: adopting the
> pooler reinforces a private-only posture instead of working against it. Connections
> from users holding the PostgreSQL `REPLICATION` role are also not supported and must
> go direct to 5432 — relevant if you later add logical replication or CDC tooling.

The pooler works with the AlloyDB Auth Proxy and the AlloyDB language connectors as well
as with direct connections. Defaults worth being aware of before you tune anything:
`max_pool_size` 50 per user-and-database pair, `max_client_connections` 5,000,
`server_idle_timeout` 600 s, `query_wait_timeout` 120 s, and `server_lifetime` 3,600 s.
The full reference is in
[`config/connection-pooling/managed-connection-pooling.md`](../../../config/connection-pooling/managed-connection-pooling.md).

### Why minimal backup retention

Three quantity-based backups on a Mon/Wed/Fri schedule, plus continuous backup with a
**1-day** PITR window. This is throwaway data. The point of enabling continuous backup at
all is to show that PITR exists and is a separate control from scheduled backups — you
need both, and they defend against different things. Production examples in this repo
use 14 to 35 days.

### Why both deletion guards are relaxed

`deletion_protection = false` and `deletion_policy = "FORCE"` together mean a single
`terraform destroy` tears this down. These are two independent guards:
`deletion_protection` is a provider-side block, and `deletion_policy` controls whether
the AlloyDB API will delete child instances along with the cluster. In dev, friction on
teardown means orphaned clusters burning quota. In production you want the friction —
see [`02-prod-ha`](../02-prod-ha/README.md).

---

## Cost considerations

Cost here is driven by, in rough order of impact:

1. **The primary instance's compute** — 2 vCPU running 24×7. This is the floor and it
   does not go away when idle.
2. **Regional storage** — grows with your data, billed on what the cluster actually
   holds. It is elastic, so you never pre-provision and never pay for empty headroom.
3. **Continuous backup storage** — a 1-day window is deliberately tiny here.
4. **VPC Flow Logs at 0.5 sampling** — small at this scale, but it is a real line item.
5. **The PSC endpoint** — a forwarding rule plus a reserved internal address. Private
   Service Connect is priced separately from AlloyDB, so check the
   [Private Service Connect pricing](https://cloud.google.com/vpc/pricing) page rather
   than assuming the consumer side is free.

Managed Connection Pooling runs inside the managed instance rather than on infrastructure
you provision. The AlloyDB documentation for the feature does not state a pricing
position either way, so confirm on the pricing page for your region before you model it
rather than assuming it is free.

There is **no idle discount and no auto-pause**. An AlloyDB instance you are not using
costs the same as one you are. For a workshop environment the correct answer is to
`terraform destroy` at the end of the day and re-apply tomorrow — the whole stack is
~15 minutes to rebuild. If you must keep the cluster, note that you cannot scale the
instance to zero; the minimum is the smallest available shape.

See [AlloyDB pricing](https://cloud.google.com/alloydb/pricing).

---

## Verification

All read-only.

```bash
PROJECT=YOUR_PROJECT_ID
REGION=us-central1
CLUSTER=alloydb-wk-dev          # name_prefix + "-dev"

# 1. Cluster exists, is READY, and is on the PSC path (pscConfig, not networkConfig).
gcloud alloydb clusters describe "$CLUSTER" \
  --region="$REGION" --project="$PROJECT" \
  --format='yaml(name,state,clusterType,pscConfig,continuousBackupConfig,automatedBackupPolicy)'
# Expect: pscConfig.pscEnabled: true, and no networkConfig.

# 2. Instance is ZONAL with 2 vCPU, SSL is enforced, and it publishes a service
#    attachment. ipAddress is empty on the PSC path - that is expected, not a fault.
gcloud alloydb instances describe "${CLUSTER}-primary" \
  --cluster="$CLUSTER" --region="$REGION" --project="$PROJECT" \
  --format='yaml(name,state,instanceType,availabilityType,machineConfig,pscInstanceConfig,clientConnectionConfig)'
# Expect: availabilityType: ZONAL, machineConfig.cpuCount: 2,
#         clientConnectionConfig.sslConfig.sslMode: ENCRYPTED_ONLY,
#         pscInstanceConfig.serviceAttachmentLink and .pscDnsName both populated

# 3. The database flags actually landed.
gcloud alloydb instances describe "${CLUSTER}-primary" \
  --cluster="$CLUSTER" --region="$REGION" --project="$PROJECT" \
  --format='value(databaseFlags)'

# 3b. Managed Connection Pooling is on, in session mode.
gcloud alloydb instances describe "${CLUSTER}-primary" \
  --cluster="$CLUSTER" --region="$REGION" --project="$PROJECT" \
  --format='yaml(connectionPoolConfig)'
# Expect: enabled: true, flags.pool_mode: session

# 4. The consumer-side endpoint exists and the producer has accepted it.
gcloud compute forwarding-rules describe "alloydb-wk-dev-psc" \
  --region="$REGION" --project="$PROJECT" \
  --format='yaml(name,IPAddress,target,pscConnectionStatus)'
# Expect: pscConnectionStatus: ACCEPTED, and target matching the service attachment
#         from step 2. A status of PENDING means the consumer project is not on the
#         instance's allow-list - check psc_allowed_consumer_projects holds project
#         NUMBERS, not project IDs.

# 5. The endpoint's address is reserved out of the app subnet.
gcloud compute addresses list --regions="$REGION" --project="$PROJECT" \
  --format='table(name,address,addressType,subnetwork.basename(),status)'

# 6. The advertised hostname resolves to that address. Run this from a host inside
#    the VPC; it is the step that is missed most often.
dig +short "$(terraform output -raw psc_dns_name)"
# Expect the same address as terraform output psc_endpoint_ip. An empty answer means
# the A record does not exist yet, and neither the Auth Proxy nor the language
# connectors will work until it does.

# 7. Confirm vCPU consumption matches the output.
terraform output vcpu_quota_consumed   # expect 2
```

Then connect:

```bash
# The Auth Proxy resolves the PSC hostname, not the IP, so the A record has to exist
# first. --psc tells the proxy to use the PSC endpoint rather than a PSA address.
# The proxy must also run somewhere with network reachability to the endpoint:
# a VM in this VPC, or your workstation over VPN/Interconnect.
./alloydb-auth-proxy --psc "$(terraform output -raw cluster_name)/instances/${CLUSTER}-primary"
psql -h 127.0.0.1 -p 5432 -U postgres -d postgres
```

`terraform output connect_via_auth_proxy` prints the exact instance URI, and the A record
you need, for you. `terraform output psc_endpoint_summary` prints the same detail from
the endpoint's point of view.

To use the pooled path instead, point the client at port 6432 rather than 5432. The
pooler accepts Auth Proxy and language-connector connections as well as direct ones,
so the only change is the port:

```bash
# Pooled endpoint. Session pool mode, so session-scoped state still behaves
# the way it does on a direct connection.
psql "host=$(terraform output -raw psc_endpoint_ip) port=6432 user=postgres dbname=postgres sslmode=require"
```

---

## Teardown

This example is configured for easy teardown — `deletion_protection = false` and
`deletion_policy = "FORCE"` are already set in `main.tf`. One command:

```bash
cd terraform/examples/01-dev-minimal
terraform destroy
```

> [!TIP]
> Because this example is on the PSC path there is no service networking peering to
> leave behind, which removes the classic reason a database `terraform destroy` hangs.
> The endpoint's forwarding rule and reserved address are destroyed with the rest of the
> stack. What Terraform does *not* clean up is a DNS record you created outside it: if
> you left `create_psc_dns = false` and added the A record in your own DNS, remove it
> yourself. A stale record pointing at a released internal address is a confusing thing
> to debug later.

Verify nothing is left consuming quota:

```bash
gcloud alloydb clusters list --region=us-central1 --project=YOUR_PROJECT_ID
```

---

## Next steps

Operations docs:

- [`docs/04-operations/sizing-guide.md`](../../../docs/04-operations/sizing-guide.md) — how to pick a shape, and why `ZONAL` vs `REGIONAL` changes your quota maths
- [`docs/04-operations/monitoring-metrics.md`](../../../docs/04-operations/monitoring-metrics.md) — the metrics that actually exist, and the 0–1 fraction trap
- [`docs/04-operations/security-hardening.md`](../../../docs/04-operations/security-hardening.md) — what this example deliberately leaves off
- [`docs/04-operations/troubleshooting-runbook.md`](../../../docs/04-operations/troubleshooting-runbook.md) — start here when the cluster create fails

Related configuration:

- [`config/connection-pooling/managed-connection-pooling.md`](../../../config/connection-pooling/managed-connection-pooling.md) — the full flag reference, pool-mode trade-offs and pooler metrics
- [`config/connection-pooling/app-side-pool-sizing.md`](../../../config/connection-pooling/app-side-pool-sizing.md) — sizing the pool inside your application, which complements the server-side pooler

Next example: **[`02-prod-ha`](../02-prod-ha/README.md)** — the same shape with
`REGIONAL` HA, pgAudit, IAM database authentication, Managed Connection Pooling in
transaction mode, real backup retention, full alerting, and deletion protection turned
on. It is the reference production deployment; if you copy one example, copy that one.

---

*Last verified: 2026-09-22 against provider google v8.3.0.*
