# AlloyDB Sizing Guide

> **The decision in one line:** on AlloyDB you size **compute only** — vCPU and RAM.
> There is no disk to provision, no IOPS tier to buy, and no autogrow threshold to
> configure. If you are carrying over a Cloud SQL or self-managed sizing spreadsheet,
> delete the storage columns before you start.

This guide covers how to pick a starting shape, how to derive that shape from a
workload you already run, how the quota arithmetic works (it will surprise you),
and how to right-size after you are live.

For "it is slow right now, what do I change", go to
[scaling-playbook.md](./scaling-playbook.md) instead.

---

## 1. The mental model: compute and storage are separate products

This is the single most important thing to internalise, and it is the most common
carryover error from Cloud SQL.

Traditional PostgreSQL — and Cloud SQL, which inherits its shape — couples the query
engine to a disk attached to the same server. You buy a disk, you buy IOPS as a
function of that disk's size, and you live in fear of the disk filling up.

AlloyDB does not work that way. Google's own description:

> "Traditional PostgreSQL couples the database engine that processes queries with
> storage on the same server. AlloyDB uses a disaggregated architecture, where
> compute and storage layers are separate and scale independently."
>
> — [AlloyDB overview](https://cloud.google.com/alloydb/docs/overview#architectural-difference-from-standard-postgresql)

And on the storage layer specifically:

> "Storage: a cloud-native, distributed storage engine that persists your data across
> multiple availability zones and **scales automatically as your data grows**."

So the sizing exercise reduces to one question: *how much CPU and RAM does my
working set and my concurrency need?*

| Concern | Cloud SQL / self-managed | AlloyDB |
| --- | --- | --- |
| Disk size | You provision it, you monitor it, you grow it | Does not exist as a provisioned resource |
| IOPS / throughput tier | Bought as a function of disk size | Not a purchasable dimension |
| "Disk full" incident class | Real, common, page-worthy | Not applicable — see the quota caveat below |
| Storage redundancy | Zonal disk + replica | Distributed across multiple zones by default |
| What you size | vCPU, RAM, **and** disk | vCPU and RAM |
| What you monitor for capacity | Disk free % | Cluster storage **quota** consumption |

> [!IMPORTANT]
> There is still a ceiling, but it is a **quota**, not a disk. A cluster has a default
> storage quota of **16 TiB** and a maximum supported size of **128 TiB**
> ([AlloyDB quotas and limits](https://cloud.google.com/alloydb/quotas)). Hitting it
> produces the error `AlloyDB instance exceeds available storage quota`. That is a
> quota-increase ticket, not a resize operation. Section 7 covers how to watch it.

### Why the security team should care about this distinction

Two practical consequences for an operational-readiness review:

1. **Your runbook library shrinks.** "Disk nearly full", "extend the volume",
   "emergency WAL cleanup because the disk filled and the instance won't start" are
   all classes of incident that do not exist here. Do not write runbooks for them.
2. **A new failure mode replaces them.** Uncontrolled data growth, a runaway
   `INSERT` loop, or an attacker filling tables no longer trips a disk alarm at 85%.
   It silently consumes quota until you hit the cluster limit. You must deliberately
   alert on the quota metrics in section 7; nothing does it for you by default.

---

## 2. Machine series selection

AlloyDB offers four machine series. They are **not** Cloud SQL tiers — there is no
`db-standard-4` or `db-custom-N-M` here, and `cloudsql.*` flags do not exist.

| Series | Positioning (Google's words) | Reach for it when |
| --- | --- | --- |
| **N2** | "a balanced price-to-performance ratio for a variety of AlloyDB workloads." **This is the default machine series.** | You have no strong reason to choose otherwise. Start here. |
| **C4A** (Axion, Arm) | "optimized price-performance and delivers predictable high performance for high demand AlloyDB workloads." | Cost-sensitive, high-throughput OLTP, and you have validated your extensions on Arm. Also the only series with a 1 vCPU shape, useful for sandboxes. |
| **C4** | "excellent performance, and the **largest vertical scale** in AlloyDB." | You need more than 128 vCPU, or you need the lowest achievable latency. |
| **Z3** | "optimized for storage-dense, I/O-intensive workloads." | Very large working sets where local-SSD cache hit rate is the dominant performance factor. |

Source: [Choose an AlloyDB machine type](https://cloud.google.com/alloydb/docs/choose-machine-type).

### Supported vCPU counts

Verified against the docs on 2026-09-22
([Scale an instance](https://cloud.google.com/alloydb/docs/instance-read-pool-scale#scale-machine-type)):

| Series | Supported vCPU counts |
| --- | --- |
| C4A | 1, 2, 4, 8, 16, 32, 48, 64, 72 |
| N2 | 2, 4, 8, 16, 32, 64, 96, 128 |
| C4 | 4, 8, 16, 24, 32, 48, 96, 144, 192, 288 |
| Z3 | 8, 14, 16, 22, 32, 44, 88 |

### Machine type naming

All current AlloyDB machine types are `highmem` shapes, and most non-N2 shapes carry
an `-lssd` (local SSD) suffix. Examples straight from the doc: `n2-highmem-4`,
`c4-highmem-4-lssd`, `c4a-highmem-4-lssd`, `z3-highmem-22-standardlssd`.

The local SSD is what backs the ultra-fast cache, which is why there is a real metric
called `instance/postgres/ultrafastcache_hitrate`. It is a property of the shape you
chose, not a feature you toggle.

> [!NOTE]
> For N2 only, the vCPU-to-RAM mapping is published directly in the scaling doc and is
> a flat **8 GB of RAM per vCPU**: 2 vCPU / 16 GB, 4 / 32, 8 / 64, 16 / 128, 32 / 256,
> 64 / 512, 96 / 768, and 128 vCPU / **864 GB** (note the last one breaks the ratio).
> Source: [Scale an instance](https://cloud.google.com/alloydb/docs/instance-read-pool-scale#scale-machine-type),
> read 2026-09-22. **This ratio should not be assumed to hold for C4A, C4 or Z3** —
> confirm the exact RAM for those shapes in the Google Cloud console or the
> [pricing calculator](https://cloud.google.com/products/calculator) before you commit
> a number to a capacity plan.

### Changing series later

You can change machine series on an existing instance, and you can mix series across
instances in the same cluster (for example an N2 primary with C4A read pool nodes).
It is an update operation, not a migration — but it does restart the instance. See
[scaling-playbook.md](./scaling-playbook.md#3-vertical-scaling-make-the-machine-bigger).

> [!WARNING]
> C4A is Arm. If you use any PostgreSQL extension outside the AlloyDB-supported set,
> or any client-side tooling that assumes x86, validate on C4A in a non-production
> cluster before committing. This is a normal Arm-migration risk, not an AlloyDB quirk,
> but it is the kind of thing that surfaces two days before go-live.

---

## 3. The sizing methodology

Tables of "recommended shapes" go stale. A measurement procedure does not. This
section is the part of the document worth keeping.

### Step 1 — Measure the source workload for 30 days

Thirty days, not seven. You need at least one month-end close, one full billing cycle,
one patch window, and ideally one marketing event. Capture:

| Signal | Why | Where to get it (source system) |
| --- | --- | --- |
| **p95 and peak CPU utilisation** | The peak drives your shape; the p95 tells you whether the peak is a spike or a plateau | Cloud Monitoring, `top`, or `pg_stat_*` sampling |
| **Working set size** | The single biggest driver of RAM. Not the database size — the *hot* portion | `pg_buffercache`, or the size of the tables/indexes touched by the top queries |
| **Total database size and 12-month growth rate** | Feeds the storage-quota decision, not the machine decision | `pg_database_size()` trended over time |
| **Peak concurrent connections, and peak *active* connections** | These are different numbers and the gap tells you whether you need a pooler | `pg_stat_activity` sampled every 10 s, grouped by `state` |
| **Peak read and write IOPS, and write throughput (MB/s)** | Sanity-check against series choice; heavy sustained write is a C4/Z3 signal | OS-level or cloud provider disk metrics |
| **Cache hit ratio per top query** | Below ~95% on a hot query means the working set does not fit in RAM | Query A in [01_top_queries.sql](../monitoring/sql/01_top_queries.sql) |
| **Top 20 queries by total execution time** | Establishes the "fix the query first" baseline before you buy hardware | [01_top_queries.sql](../monitoring/sql/01_top_queries.sql) |

> [!TIP]
> Sample `pg_stat_activity` on a timer and store it. A single point-in-time
> `SELECT count(*) FROM pg_stat_activity` taken during a quiet afternoon is the most
> common source of undersized connection planning. Query B in
> [02_connections_and_locks.sql](../monitoring/sql/02_connections_and_locks.sql)
> gives you the census grouped by `application_name`.

### Step 2 — Convert observations into a starting shape

Work through these in order. Every number below is **engineering guidance for this
workshop, not a Google-published figure.**

**a. vCPU from CPU utilisation.**
Take peak vCPU-seconds consumed, not percentage. If the source system has 16 vCPU and
peaks at 70%, that is ~11.2 vCPU of real demand. Target landing at **50–60% peak
utilisation** on the new instance so you have headroom for growth, vacuum, and
failover-induced cache-cold periods. 11.2 / 0.55 ≈ 20 vCPU → round up to the next
supported shape (32 on N2, or 24 on C4).

**b. RAM from working set.**
Aim for the hot working set plus index pages to fit in RAM with room for connection
overhead and sort/hash memory. Because all AlloyDB shapes are `highmem`, RAM usually
comes along for free once you have chosen vCPU — verify it does. If your working set
is 300 GB, an N2 32 vCPU / 256 GB shape is not enough, and you should move up rather
than accept a permanently cold cache.

**c. Cross-check against connections.**
A database can only genuinely execute as many queries concurrently as it has cores.
The house rule used throughout this repo is **2–4 concurrent server connections per
vCPU** — see [app-side-pool-sizing.md](../config/connection-pooling/app-side-pool-sizing.md).
If your measured peak *active* connections is wildly above 4x your candidate vCPU
count, the answer is a connection pooler rather than a bigger machine. On AlloyDB that
means [managed connection pooling](../config/connection-pooling/managed-connection-pooling.md),
which is part of the instance and needs no compute of its own.

**d. Choose the series.** Default to N2. Move to C4A for price/performance if Arm is
validated, C4 if you need >128 vCPU or the lowest latency, Z3 if the working set is
enormous and I/O-bound.

**e. Do the quota arithmetic** — section 5. Do this *before* you raise the Terraform PR.

### Step 3 — Validate after cutover

Run for two weeks and check all of these. If any fails, resize; do not wait for an
incident to tell you.

| Check | Metric | Starting target (calibrate — not a Google recommendation) |
| --- | --- | --- |
| CPU has headroom | `instance/cpu/average_utilization` | sustained below ~0.60 |
| No hidden per-core saturation | `instance/cpu/maximum_utilization` | peaks below ~0.85 |
| Memory is not pressured | `instance/memory/min_available_memory` | not trending toward zero |
| Cache is working | `instance/postgres/ultrafastcache_hitrate` | stable and high; a downward trend means the working set is outgrowing the shape |
| Connections are under control | `instance/postgres/total_connections` ÷ `instance/postgres/connections_limit` | below ~0.80 |
| Query latency matches or beats the old system | `database/postgresql/insights/aggregate/latencies` | your own SLO |

> [!CAUTION]
> `instance/cpu/average_utilization` and `instance/cpu/maximum_utilization` are
> declared with unit `10^2.%` and a description that says "from 0 to 100", but the
> **actual value returned by the API is a fraction between 0 and 1**. A live sample
> read 0.042357 for a near-idle instance. In a Terraform alert policy you write
> `threshold_value = 0.85`, not `85`. Writing `85` produces a policy that validates,
> applies cleanly, and never fires.

Also note: the metric `alloydb.googleapis.com/instance/cpu/utilization` — without the
`average_`/`maximum_` prefix — **does not exist**. If you find it in a dashboard
someone copied from a blog post, that dashboard is showing you nothing.

---

## 4. Workload archetypes — starting points only

> [!IMPORTANT]
> Every row below is a **starting point for a conversation**, produced by the authors
> of this repo. None of it is a Google-published sizing recommendation. Use it to
> open a capacity discussion, then replace it with numbers from section 3 as soon as
> you have measurements.

| Archetype | Primary starting shape | HA? | Read pool | Columnar engine | Notes |
| --- | --- | --- | --- | --- | --- |
| **Small internal app / sandbox** | C4A 1–2 vCPU, or N2 2 vCPU | No — use a basic instance | None | Off | A [basic instance](https://cloud.google.com/alloydb/docs/basic-instance) has a single node and no standby, which halves the vCPU quota cost. Non-production only. |
| **Departmental OLTP** | N2 4–8 vCPU | Yes | 0–2 nodes for reporting | Off | The commonest real case. Put reporting on a read pool early so a bad report cannot take down the app. |
| **High-throughput OLTP** | C4A or N2 16–32 vCPU | Yes | 2+ nodes | Off | Plan for connection pooling from the start at this size — see [managed-connection-pooling.md](../config/connection-pooling/managed-connection-pooling.md). |
| **Mixed HTAP** | N2 or C4 32+ vCPU, sized for **two** working sets | Yes | 2+ nodes | **On** | See section 8 — columnar memory is carved out of the same RAM as the buffer cache. |
| **Read-heavy (read:write ≫ 10:1)** | Keep the primary modest, e.g. N2 8–16 vCPU | Yes | 4+ nodes, scale horizontally | Optional | Spend on read nodes rather than on a giant primary. Mind the 20-node cluster budget. |

---

## 5. Quota arithmetic — the thing that blocks deployments

Every hard number in this section comes from
[AlloyDB quotas and limits](https://cloud.google.com/alloydb/quotas) (page read live
2026-09-22).

| Limit | Default | Maximum |
| --- | --- | --- |
| Clusters per project per region | 3–10, depending on project history | 20 |
| vCPUs per project per region | 10,000 | — |
| Storage per cluster | 16 TiB | 128 TiB |
| `max_connections` | 1,000 | 240,000 |

> [!WARNING]
> **A highly available primary instance consumes two VMs' worth of vCPU quota, not
> one.** The active node and the standby node are both real VMs and both count. A read
> pool consumes one VM per node. This is documented on the quotas page, and it is the
> most common reason a well-planned AlloyDB rollout stops at `terraform apply` with
> `VCPUsUsedPerProjectPerRegion`.

This also means your HA primary costs 2x the compute, which is the correct way to
think about it commercially as well as for quota.

### Worked example

A realistic mid-size platform landing in `us-central1`:

```text
Production cluster
  Primary, HA, N2 32 vCPU        32 vCPU x 2 VMs (active + standby)   =  64
  Read pool, 4 nodes x 16 vCPU   16 vCPU x 4 nodes                    =  64

Staging cluster
  Primary, HA, N2 8 vCPU          8 vCPU x 2 VMs                      =  16
  Read pool, 2 nodes x 8 vCPU     8 vCPU x 2 nodes                    =  16

Dev cluster
  Primary, BASIC, N2 4 vCPU       4 vCPU x 1 VM (no standby)          =   4
                                                                       -----
                                        Total vCPU quota consumed     = 164
                            Clusters consumed in this region          =   3
```

Note two things. First, the naive total — adding up only the "instance sizes" you
typed into Terraform — is 32 + 64 + 8 + 16 + 4 = **124**. The real figure is **164**,
a 32% underestimate, entirely because of the HA standby nodes. Second, three clusters
in one region may already sit at the low end of the clusters-per-region default range.

### Check your actual usage before you plan

Start from what is actually deployed, not from what the Terraform state claims:

```bash
# Enumerate existing clusters and instances so your arithmetic starts from reality.
gcloud alloydb clusters list \
  --region=us-central1 \
  --project=bryanko-databases-demo1 \
  --format='table(name, state, clusterType)'

gcloud alloydb instances list \
  --cluster=CLUSTER_ID \
  --region=us-central1 \
  --project=bryanko-databases-demo1 \
  --format='table(name, instanceType, machineConfig.cpuCount, availabilityType, readPoolConfig.nodeCount)'
```

Quota consumption itself is best read in the console under
**IAM & Admin → Quotas**, filtered to the AlloyDB API, because that view shows the
current limit and the current usage side by side.

> [!TIP]
> Treat the vCPU quota as a **blast-radius control**, not just a capacity limit. A
> deliberately tight per-region vCPU quota caps how much compute a compromised
> pipeline or a mis-parameterised Terraform module can provision before something
> stops it. Raise it consciously with a justification, not pre-emptively to a large
> round number.

Finally, remember that quota is not a capacity guarantee. Having 10,000 vCPU of quota
in a region does not mean the region can physically supply you a 288 vCPU C4 instance
on demand. For unusually large shapes, talk to your account team before the change
window rather than discovering the constraint during it.

---

## 6. Storage sizing: there isn't one, but there is a quota

Restating the key point because it is worth repeating: **you do not provision storage
on AlloyDB.** The storage layer grows automatically as your data grows. There is no
`disk_size` argument in `google_alloydb_cluster` or `google_alloydb_instance`, and
looking for one is a good way to notice you are still thinking in Cloud SQL terms.

What you do instead is **monitor quota consumption**.

| Metric | Type | What it tells you |
| --- | --- | --- |
| `cluster/storage/usage` | GAUGE, bytes | Raw bytes stored by the cluster |
| `quota/storage_usage_per_cluster/usage` | GAUGE | Quota-accounted usage |
| `quota/storage_usage_per_cluster/limit` | GAUGE | The current quota ceiling for this cluster |
| `quota/storage_usage_per_cluster/exceeded` | DELTA | Increments when a request is rejected for quota |

The `usage` and `limit` pair is the important one, because it lets you write a
**ratio** alert rather than hardcoding 16 TiB into a policy that silently becomes
wrong the day someone raises the quota.

```text
# Cloud Monitoring MQL sketch: storage quota consumption as a fraction.
# Alert when this exceeds a level you choose - see the caveat below.
fetch alloydb.googleapis.com/Cluster
| { metric 'alloydb.googleapis.com/quota/storage_usage_per_cluster/usage'
  ; metric 'alloydb.googleapis.com/quota/storage_usage_per_cluster/limit' }
| join
| value [ratio: val(0) / val(1)]
```

> [!IMPORTANT]
> Google does not publish a recommended alerting threshold for this. As a **starting
> point requiring calibration for your growth rate**, teams in this repo alert at a
> ratio of 0.75 for a warning and 0.90 for a page. Pick your own numbers by looking at
> your measured monthly growth and asking "how many days of runway does this leave me,
> given that a quota increase takes business days, not minutes?"

### Raising the limit

The 16 TiB default is a **quota**, so you raise it the same way you raise any other
Google Cloud quota: through **IAM & Admin → Quotas & System Limits** in the console,
filtered to the AlloyDB API, or through a support case. The maximum supported cluster
size is 128 TiB. There is also an Active Assist recommender that will flag clusters
approaching the limit — see
[Increase cluster storage quota](https://cloud.google.com/alloydb/docs/recommender-increase-cluster-storage-quota).

Because a quota increase is a human-in-the-loop process, request it on the basis of a
trend, not on the basis of an alert that has already fired.

---

## 7. Columnar engine memory sizing

The columnar engine gives you an in-memory column store for analytical queries running
against the same tables as your OLTP traffic. It is the main reason to consider
AlloyDB instead of exporting to a warehouse for "reporting on live data".

The sizing consequence is blunt: **the column store is carved out of the same instance
memory as the row-store buffer cache.** Enabling it means you are now sizing for two
working sets on one machine.

| Fact | Value | Source |
| --- | --- | --- |
| Default allocation | **30% of the instance's memory**, auto-adjusted when you resize the instance | [Configure the columnar engine](https://cloud.google.com/alloydb/docs/columnar-engine/configure#configure-memory) |
| Recommended maximum | **50%** | same |
| Hard maximum | **70%** | same |
| Explicit override flag | `google_columnar_engine.memory_size_in_mb` | same |
| Minimum value for that flag | **128** (MiB) | AlloyDB Admin API `supportedDatabaseFlags` |
| Restart required to change it | **Yes** | AlloyDB Admin API `supportedDatabaseFlags` |
| Enable flag | `google_columnar_engine.enabled` (restart required) | AlloyDB Admin API `supportedDatabaseFlags` |
| Auto-population | `google_columnar_engine.enable_auto_columnarization` (no restart) | AlloyDB Admin API `supportedDatabaseFlags` |

> [!WARNING]
> If you enable the columnar engine on an instance that was sized to exactly fit its
> row-store working set, you have just taken 30% of that cache away. The symptom is a
> falling `instance/postgres/ultrafastcache_hitrate` and OLTP latency regression that
> looks unrelated to the analytics work you just enabled. Size up *first*, enable
> second.

### How to size it

1. Start by **leaving the flag unset**. The 30% default auto-adjusts when you resize
   the instance; a hardcoded MiB value does not, and will quietly become wrong the
   next time someone scales the machine.
2. Use Google's own recommendation function rather than guessing. See
   [Recommend column store memory size](https://cloud.google.com/alloydb/docs/columnar-engine/manage-content-recommendations#recommend-populate).
3. Only set `google_columnar_engine.memory_size_in_mb` when you have a specific,
   measured reason — for example, a fixed and well-understood set of columnarised
   tables whose size you want to guarantee.
4. Treat 50% as your practical ceiling. The docs allow 70%, but at that point you are
   running an analytics engine with a transactional database attached, and you should
   ask whether a read pool with the columnar engine enabled is the better topology.

```hcl
# Enabling the columnar engine via database flags on the instance.
# Both of these require an instance restart - plan a window.
resource "google_alloydb_instance" "primary" {
  cluster       = google_alloydb_cluster.main.name
  instance_id   = "primary"
  instance_type = "PRIMARY"

  machine_config {
    # Sized for row-store working set PLUS the column store. If your row-store
    # working set is ~180 GB, do not pick a 256 GB shape and then hand 30% of it
    # to the columnar engine.
    cpu_count = 32
  }

  database_flags = {
    # Restart required.
    "google_columnar_engine.enabled" = "on"

    # Deliberately not setting google_columnar_engine.memory_size_in_mb.
    # The 30% default tracks the instance size automatically; a hardcoded value
    # does not, and becomes stale the moment anyone changes cpu_count.
  }
}
```

---

## 8. Cost drivers and how sizing maps to the bill

AlloyDB bills on consumption. Per the
[AlloyDB overview](https://cloud.google.com/alloydb/docs/overview#alloydb-pricing),
the dimensions are:

- **Instance resources** — the machine type (vCPU and RAM) of your primary and read
  pool instances.
- **Storage** — the amount of data in the cluster's flexible storage layer.
- **Networking** — egress traffic from your instances.

Backup storage is billed separately from cluster storage. Current rates for all of
these live on the [AlloyDB pricing page](https://cloud.google.com/alloydb/pricing) —
this document deliberately quotes no dollar figures, because they change and a stale
rate in a workshop doc is worse than no rate.

How each sizing decision lands on the invoice:

| Decision | Compute cost | Storage cost |
| --- | --- | --- |
| Double the primary's vCPU | Roughly doubles | No change |
| Enable HA on the primary | **Doubles** (active + standby are both billed VMs) | **No change** — storage is shared, not duplicated |
| Add a read pool node | +1 node's worth | **No change** — read pools share the cluster's storage |
| Enable the columnar engine | No change by itself, but usually forces a larger shape | No change |
| Data grows | No change | Grows proportionally |
| Longer backup retention | No change | Increases *backup* storage, billed separately |

> [!TIP]
> The "HA doubles compute but not storage" property is the most useful cost fact in
> this table. It means enabling HA on a small instance is cheap in absolute terms, and
> it means the cost argument against HA gets *weaker*, not stronger, for
> storage-heavy databases. Treat a non-HA production primary as a deliberate,
> documented risk acceptance, not a cost optimisation.

---

## 9. Right-sizing an existing instance

You are live. Is the instance the right size? Use these four metrics, all confirmed to
exist via the Cloud Monitoring `metricDescriptors` API on 2026-09-22.

| Metric | Reading it |
| --- | --- |
| `instance/cpu/average_utilization` | The headline number. Fraction 0–1. |
| `instance/cpu/maximum_utilization` | The per-core maximum. Fraction 0–1. |
| `instance/memory/min_available_memory` | Bytes. The low-water mark of free memory. |
| `instance/postgres/ultrafastcache_hitrate` | Cache effectiveness. A sustained decline means the working set is outgrowing the instance. |

### The diagnostic that matters: average vs maximum

Comparing the two CPU metrics tells you something a single utilisation number cannot.

| Pattern | Interpretation | Action |
| --- | --- | --- |
| average low, maximum low | Over-provisioned | Scale down (section 10 of [scaling-playbook.md](./scaling-playbook.md#9-scaling-down-and-cost-control)) |
| average high, maximum high | Genuinely CPU-bound across the board | Scale up, **after** checking the top queries |
| average **low**, maximum **high** | Serialised work — one hot core. Usually a single expensive query, a lock convoy, or a single-threaded background job | Scaling up adds cores this workload cannot use, so start with [01_top_queries.sql](../monitoring/sql/01_top_queries.sql) instead |
| average high, memory low, hit rate falling | Working set no longer fits | Scale up for RAM, or reduce the working set with better indexes |

That third row is the money one. It is the case where scaling up costs you money and
delivers nothing, and it is common.

```bash
# Read the last hour of average CPU utilisation directly from the Monitoring API.
# Remember: the returned values are FRACTIONS between 0 and 1, despite the unit
# string saying 10^2.% and the description saying "from 0 to 100".
PROJECT=bryanko-databases-demo1
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
HOUR_AGO=$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)

curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://monitoring.googleapis.com/v3/projects/${PROJECT}/timeSeries?\
filter=metric.type%3D%22alloydb.googleapis.com%2Finstance%2Fcpu%2Faverage_utilization%22\
&interval.startTime=${HOUR_AGO}&interval.endTime=${NOW}" \
  | jq '.timeSeries[] | {instance: .resource.labels.instance_id,
                         latest: .points[0].value.doubleValue}'
```

The monitored resource type is `alloydb.googleapis.com/Instance`, and its labels are
`project_id`, `location`, `cluster_id`, `instance_id`. If you have seen
`resource_container` used as the project label in an AlloyDB filter, it is wrong and
the filter will match nothing.

### Let Google tell you

Active Assist publishes an
[Optimize underprovisioned instances](https://cloud.google.com/alloydb/docs/recommender-optimize-underprovisioned-cluster)
recommender for AlloyDB. It is worth wiring into your review cadence as a
cross-check against your own analysis — not as a replacement for it.

---

## Where to go next

- **"It's slow right now"** → [scaling-playbook.md](./scaling-playbook.md)
- **Application pool settings** → [app-side-pool-sizing.md](../config/connection-pooling/app-side-pool-sizing.md)
- **Managed connection pooling** → [managed-connection-pooling.md](../config/connection-pooling/managed-connection-pooling.md)
- **Finding the expensive queries** → [01_top_queries.sql](../monitoring/sql/01_top_queries.sql)
- **Connection and lock census** → [02_connections_and_locks.sql](../monitoring/sql/02_connections_and_locks.sql)
- **Vacuum and bloat** → [03_vacuum_and_bloat.sql](../monitoring/sql/03_vacuum_and_bloat.sql)

---

*Last verified: 2026-09-22 against provider google v8.3.0. Re-verify hard numbers before reuse.*
