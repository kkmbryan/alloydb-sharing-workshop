# AlloyDB for PostgreSQL — Operations Workshop

Reference architecture, Terraform samples and operational guidance for running
**AlloyDB for PostgreSQL** on Google Cloud.

This repository is the companion material for section 4 of the AlloyDB
workshop — **Operations and Best Practices**. Sections 1–3 (Overview,
Architecture, AlloyDB AI) are delivered as slides; this repo is the part you
take home and actually use.

Everything here is designed to be **copied and adapted**, not deployed as-is.

---

## Start here

| If you want to… | Go to |
| --- | --- |
| See the smallest working AlloyDB deployment | [`terraform/examples/01-dev-minimal`](terraform/examples/01-dev-minimal) |
| Copy a production-ready configuration | [`terraform/examples/02-prod-ha`](terraform/examples/02-prod-ha) |
| Understand the hardened security baseline | [`docs/security-hardening.md`](docs/security-hardening.md) |
| Size an instance for a real workload | [`docs/sizing-guide.md`](docs/sizing-guide.md) |
| Know what to monitor and alert on | [`docs/monitoring-metrics.md`](docs/monitoring-metrics.md) |
| Fix something that is broken right now | [`docs/troubleshooting-runbook.md`](docs/troubleshooting-runbook.md) |
| Prove audit coverage to a compliance team | [`docs/audit-logging-and-siem.md`](docs/audit-logging-and-siem.md) |

---

## Repository layout

```
.
├── docs/        Operational guidance — the written material
├── terraform/
│   ├── modules/               Four reusable modules
│   └── examples/              Five complete, runnable configurations (all on PSC)
├── config/
│   ├── database-flags/        Curated flag baselines with restart annotations
│   └── connection-pooling/    Managed Connection Pooling and app-side sizing
├── monitoring/
│   ├── dashboards/            Cloud Monitoring dashboard JSON
│   └── sql/                   In-database diagnostic queries
└── scripts/                   Validation and security posture audit
```

### Terraform examples

All five examples standardise on **Private Service Connect (PSC)** rather than VPC peering.
See [`terraform/examples/README.md`](terraform/examples/README.md) for the architectural
rationale, consumer responsibilities, and guidance if your organisation uses PSA.

| Example | Demonstrates | Production ready |
| --- | --- | --- |
| [01-dev-minimal](terraform/examples/01-dev-minimal) | VPC + PSC, single zonal instance. The one to read first. | No — no HA |
| [02-prod-ha](terraform/examples/02-prod-ha) | Regional HA, managed pooling, IAM auth, pgAudit, full alerting | **Yes** |
| [03-read-pool-scaling](terraform/examples/03-read-pool-scaling) | Read pools with per-pool PSC endpoints and workload isolation | Yes |
| [04-secure-cmek](terraform/examples/04-secure-cmek) | CMEK, connector-only access, SIEM export, hardened audit baseline | **Yes — hardened** |
| [05-cross-region-dr](terraform/examples/05-cross-region-dr) | Cross-region secondary cluster, dual regional PSC endpoints, DR runbooks | Yes |

### Terraform modules

| Module | Purpose |
| --- | --- |
| [`alloydb-cluster`](terraform/modules/alloydb-cluster) | Cluster, primary instance, read pools, backups, CMEK, pooling (PSA or PSC) |
| [`network`](terraform/modules/network) | VPC, subnet, firewall rules (optional PSA peering toggle) |
| [`psc-endpoint`](terraform/modules/psc-endpoint) | Consumer-side PSC endpoint (forwarding rule + address) and optional private DNS |
| [`observability`](terraform/modules/observability) | Nine alert policies and a dashboard, using verified metric names |

### Operations documentation

| Document | Covers |
| --- | --- |
| [sizing-guide.md](docs/sizing-guide.md) | Machine series, sizing methodology, quota arithmetic, cost drivers |
| [scaling-playbook.md](docs/scaling-playbook.md) | Scale up vs out vs pool vs fix the query — a decision tree |
| [security-hardening.md](docs/security-hardening.md) | Network isolation, CMEK, IAM, SSL, password policy, VPC-SC |
| [audit-logging-and-siem.md](docs/audit-logging-and-siem.md) | Cloud Audit Logs, pgAudit, volume control, SIEM export |
| [monitoring-metrics.md](docs/monitoring-metrics.md) | Metric reference, golden signals, what to alert on |
| [maintenance-and-upgrades.md](docs/maintenance-and-upgrades.md) | Maintenance windows, restart-causing changes, version upgrades |
| [troubleshooting-runbook.md](docs/troubleshooting-runbook.md) | Symptom-driven incident runbooks |

---

## Quick start

```bash
# 1. Pick an example
cd terraform/examples/01-dev-minimal

# 2. Supply your values
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars

# Prefer keeping the password out of the file entirely:
export TF_VAR_initial_user_password="$(openssl rand -base64 24)"

# 3. Review before you apply
terraform init
terraform plan

# 4. Apply
terraform apply
```

Required APIs:

```bash
gcloud services enable \
  alloydb.googleapis.com \
  compute.googleapis.com \
  monitoring.googleapis.com \
  dns.googleapis.com
# servicenetworking.googleapis.com is only needed if using PSA
# cloudkms.googleapis.com is needed for CMEK (04-secure-cmek)
```

> [!WARNING]
> These examples create billable resources. AlloyDB has no free tier, and a
> regional HA instance bills for **two** nodes. Destroy anything you are not
> using — each example's README has explicit teardown steps.

---

## Eleven things worth knowing before you start

These are the points that most often surprise teams new to AlloyDB. Each is
covered in depth in the linked document.

**1. You size compute, not storage.**
Storage is regional, disaggregated and grows automatically. There is no disk
to provision and no disk to run out of — but there *is* a per-cluster storage
**quota** (16 TiB default, 128 TiB maximum). → [sizing-guide](docs/sizing-guide.md)

**2. A regional primary consumes double the vCPU quota.**
HA means an active node plus a standby, and both count against
`VCPUsUsedPerProjectPerRegion`. An 8-vCPU HA primary costs 16 vCPUs of quota
before you add a single read pool node. → [sizing-guide](docs/sizing-guide.md)

**3. PSA or PSC is a permanent decision.**
The private access method is fixed at cluster creation and cannot be changed
afterwards. This repository standardises on Private Service Connect (PSC) because
it eliminates VPC peering, prevents address-space collisions, and scopes access
by project number. Choose deliberately. → [security-hardening](docs/security-hardening.md)

**4. Raising `max_connections` is almost always the wrong move.**
Google's own guidance table plateaus at 5,000 regardless of instance size.
Connections cost memory that would otherwise cache your data. AlloyDB has a
pooler built into the service — Managed Connection Pooling — so there is no
PgBouncer fleet to run, patch or credential. It is off by default, listens on
port 6432, and is not supported on public IP, so turning it on reinforces a
private-only posture.
→ [managed-connection-pooling](config/connection-pooling/managed-connection-pooling.md)

**5. Utilisation metrics are fractions, not percentages.**
`instance/cpu/maximum_utilization` returns `0.85`, not `85` — even though the
console renders a percentage and the metric description says "0 to 100". Get
this wrong in an alert policy and it simply never fires.
→ [monitoring-metrics](docs/monitoring-metrics.md)

**6. `instance/cpu/utilization` does not exist.**
It is `average_utilization` or `maximum_utilization`. A wrong metric name
passes `terraform validate` and then silently does nothing.
→ [monitoring-metrics](docs/monitoring-metrics.md)

**7. Enabling pgAudit does not enable auditing.**
`pgaudit.log` defaults to `none`. You must also set it, run
`CREATE EXTENSION pgaudit` in **each** database, and enable Data Access audit
logs at the project level. Miss any one and you capture nothing.
→ [audit-logging-and-siem](docs/audit-logging-and-siem.md)

**8. `gcloud ... --database-flags` replaces the entire flag set.**
Any flag you omit reverts to its default. Manage flags declaratively in
Terraform instead. → [config/database-flags](config/database-flags)

**9. Maintenance drops your connections.**
Routine maintenance, machine type changes and failovers all interrupt
connections. Applications need reconnect and retry logic with backoff — this
is a hard requirement, not a nice-to-have.
→ [maintenance-and-upgrades](docs/maintenance-and-upgrades.md)

**10. Cross-region replication does not protect you from yourself.**
A bad migration replicates to your DR cluster in seconds. Region failure and
logical corruption are different problems: replication solves the first,
point-in-time recovery solves the second. You need both.
→ [terraform/examples/05-cross-region-dr](terraform/examples/05-cross-region-dr)

**11. Your autovacuum tuning knowledge may not transfer.**
AlloyDB enables *adaptive autovacuum* by default, which adjusts CPU, I/O,
worker count and memory for vacuum against the live workload, and logs the
blockers holding vacuum back. The documentation is explicit that you do not
need to set the standard vacuum flags, and that values you do set become
inputs the adaptive logic works around. The reflex to globally lower
`autovacuum_vacuum_scale_factor` is counterproductive here — prefer per-table
settings. → [config/database-flags](config/database-flags)

---

## Validating changes

```bash
./scripts/validate.sh          # fmt check + terraform validate on everything
./scripts/validate.sh --fix    # rewrite files to canonical format
```

Neither authenticates to Google Cloud nor creates resources. CI runs the same
script.

Audit a deployed cluster against the hardened baseline:

```bash
./scripts/verify-security-posture.sh --cluster CLUSTER_ID --region REGION
```

This is strictly read-only and safe to run against production.

---

## On the accuracy of this material

AlloyDB changes quickly, and a lot of third-party writing about it is either
stale or quietly confused with Cloud SQL. The content here was grounded
against primary sources rather than search results:

- **Terraform schemas** — checked against `terraform providers schema -json`
  for `hashicorp/google` **v8.3.0**, not against documentation.
- **Database flags** — enumerated from the AlloyDB Admin API
  `supportedDatabaseFlags` endpoint (423 flags), including which require a
  restart.
- **Metric names, kinds and units** — enumerated from the Cloud Monitoring
  `metricDescriptors` API (122 metrics) against a live AlloyDB instance.
- **Value scales** — confirmed by sampling real time series, which is how the
  fraction-versus-percentage trap in point 5 above was caught.
- **Quotas** — read from the live
  [quotas page](https://cloud.google.com/alloydb/quotas).

Where something could not be verified, it is labelled as unverified guidance
rather than stated as fact. Where a threshold is suggested, it is labelled as
a starting point — **Google publishes no official numeric alerting thresholds
for AlloyDB**, and anyone who tells you otherwise is quoting a blog.

> [!NOTE]
> Verified 2026-09-22. Re-verify hard numbers before relying on them; this is
> reference material, not a service contract.

---

## Further reading

- [AlloyDB documentation](https://cloud.google.com/alloydb/docs)
- [Quotas and limits](https://cloud.google.com/alloydb/quotas)
- [Supported database flags](https://cloud.google.com/alloydb/docs/reference/database-flags)
- [Operational guidelines](https://cloud.google.com/alloydb/docs/reference/operational-guidelines)
- [Pricing](https://cloud.google.com/alloydb/pricing)
- [SLA](https://cloud.google.com/alloydb/sla)

## License

Apache 2.0 — see [LICENSE](LICENSE).
