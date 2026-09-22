# Managed Connection Pooling

AlloyDB has a connection pooler built into the service. It runs inside the
managed instance, is configured through the same Terraform resource as
everything else, and needs no VMs, patching or credential store of its own.

This is the recommended way to pool connections to AlloyDB. This repository
deliberately does not ship a PgBouncer configuration, for reasons set out in
[Why not run your own pooler](#why-not-run-your-own-pooler) below.

---

## Why pool at all

Every PostgreSQL connection is a separate backend process with its own memory,
drawn from the same pool that serves the buffer cache. AlloyDB derives
`max_connections` from the instance machine shape, so raising it trades
throughput for connection count. Past a few thousand connections you lose more
to context switching and lock contention than you gain in concurrency.

Google's own guidance table makes the point: the recommended `max_connections`
doubles with instance size (500, 1000, 2000, 4000) and then **plateaus at
5000** for every larger shape. Beyond that point, the answer is a pooler rather
than a bigger number.

A pooler lets a large number of application clients share a small number of
server connections, and absorbs connection spikes rather than passing them
through to the database.

---

## Enabling it

Managed connection pooling is **disabled by default**. In this repository the
`alloydb-cluster` module exposes it through the `connection_pool` variable:

```hcl
module "alloydb" {
  source = "../../modules/alloydb-cluster"

  # ... cluster configuration ...

  connection_pool = {
    enabled = true
    flags = {
      "pool_mode"              = "transaction"
      "max_pool_size"          = "50"
      "query_wait_timeout"     = "120"
      "server_idle_timeout"    = "600"
    }
  }
}
```

A worked example lives in
[`terraform/examples/02-prod-ha`](../../terraform/examples/02-prod-ha).

> [!NOTE]
> **Flag naming differs between gcloud and Terraform.** The gcloud flags are
> named `--connection-pooling-pool-mode` and so on. In the Terraform `flags`
> map, drop the `connection-pooling-` prefix and replace dashes with
> underscores: `pool_mode`. Getting this wrong produces a confusing API error
> rather than a helpful validation message.

---

## Connecting

Connecting is identical to a direct connection except for the port. Managed
connection pooling listens on **6432**; direct connections continue to use
5432.

```bash
psql "postgresql://USERNAME:PASSWORD@IP_ADDRESS:6432/postgres"
```

Any user on the AlloyDB instance can connect through the pooler. It also works
with the **AlloyDB Auth Proxy** and the **AlloyDB Language Connectors** — worth
stating explicitly, because several third-party write-ups claim otherwise. When
the Auth Proxy is in use, its connections are pooled separately, in a pool
containing only Auth Proxy connections.

---

## Choosing a pool mode

| Mode | A server connection is held | Use when |
|---|---|---|
| `transaction` (default) | for the duration of one transaction | Most OLTP applications. Gives the highest reuse. |
| `session` | for as long as the client stays connected | Your application needs session state that transaction mode does not support. |

### Compatibility checklist for transaction mode

In transaction pooling mode the following are **not supported**:

- `SET` / `RESET`
- `LISTEN`
- `WITH HOLD CURSOR`
- `PREPARE` / `DEALLOCATE`
- `PRESERVE` / `DELETE ROW` temp tables
- `LOAD`
- Session-level advisory locks
- Protocol-level prepared plans

This list is the single most important thing to check before enabling
transaction mode. Most ORMs and connection libraries are fine, but
session-level advisory locks and protocol-level prepared statements catch
people out — some database migration tools use advisory locks to serialise
migrations, and some drivers use protocol-level prepared statements by default.

If your application needs any of the above, use `session` mode, which still
provides pooling benefits with less aggressive reuse. `max_prepared_statements`
exists to support prepared statements in transaction mode; it defaults to `0`.

---

## Configuration reference

All values below are the documented defaults.

| Terraform flag key | gcloud flag | Default | Notes |
|---|---|---|---|
| `pool_mode` | `--connection-pooling-pool-mode` | `transaction` | Or `session`. |
| `max_pool_size` | `--connection-pooling-max-pool-size` | `50` | Per user and database pair. |
| `min_pool_size` | `--connection-pooling-min-pool-size` | `0` | |
| `max_client_connections` | `--connection-pooling-max-client-connections` | `5000` | Range 1 – 262,042. |
| `client_connection_idle_timeout` | `--connection-pooling-client-connection-idle-timeout` | `0` s | Range 0 – 2,147,483. `0` disables. |
| `server_idle_timeout` | `--connection-pooling-server-idle-timeout` | `600` s | Range 0 – 2,147,483. |
| `query_wait_timeout` | `--connection-pooling-query-wait-timeout` | `120` s | Range 0 – 2,147,483. |
| `max_prepared_statements` | `--connection-pooling-max-prepared-statements` | `0` | Transaction mode only. |
| `ignore_startup_parameters` | `--connection-pooling-ignore-startup-parameters` | — | Parameters not tracked in startup packets by default. |
| `server_lifetime` | `--connection-pooling-server-lifetime` | `3600` s | Max time a server connection is unused before closure. |
| `stats_users` | `--connection-pooling-stats-users` | — | Comma-separated users allowed to reach the stats console. **gcloud only.** |

`max_pool_size` is per user and database pair, not per instance. If you have
several application users, the total server connections the pooler may open is
`max_pool_size × (user, database) pairs` — size that against the instance's
`max_connections`, not against `max_pool_size` alone.

A reasonable starting point for a CPU-bound OLTP workload is a server pool of
roughly **2 to 4 × vCPU count**. Start at 2×, measure, and grow only while
throughput is still improving. If adding server connections stops improving
throughput, the bottleneck is the database rather than the pool — scale the
instance or fix the queries instead.

---

## Limitations to be aware of

Beyond the transaction-mode SQL feature list above:

- **Not supported for public IP connections.** For a security-conscious
  deployment this is a feature rather than a limitation — see below.
- **Connections from users holding the PostgreSQL `REPLICATION` role are not
  supported.** Logical replication and CDC tooling must connect directly on
  5432.
- **Disabled by default**, so it must be explicitly enabled.

---

## Monitoring

Four metrics are published under `alloydb.googleapis.com`:

| Metric | Unit | Labels | What it tells you |
|---|---|---|---|
| `database/conn_pool/client_connections` | count | `status`, `pooler` | Client connections per database, grouped by status. |
| `database/conn_pool/server_connections` | count | `status`, `pooler` | Server connections per database, grouped by status. |
| `database/conn_pool/client_connections_avg_wait_time` | µs | `pooler` | Average time clients spend waiting for a server connection. |
| `database/conn_pool/num_pools` | count | `pooler` | Number of pools per database. |

`client_connections_avg_wait_time` is the one to alert on. A rising wait time
means clients are queuing for server connections, which indicates
`max_pool_size` is too small for the offered load — or that queries are holding
server connections too long, which is a query problem rather than a pool
problem. Check both before increasing the pool size.

If you set `stats_users`, those users can additionally reach a statistics
console backed by an `alloydb_mcp_stats_{pooler_id}` database per pooler.

---

## Why not run your own pooler

PgBouncer is good software and this is not a criticism of it. But for a team
evaluating AlloyDB — particularly one assessing operational and security
posture — self-managing a pooler adds work and risk that the managed option
does not:

| Concern | Self-managed pooler | Managed connection pooling |
|---|---|---|
| Compute to patch | A VM fleet or sidecar you own | None |
| Credentials | `userlist.txt` or an `auth_query` role, stored by you | None added |
| TLS | A second termination point to configure and rotate | None added |
| Availability | Single-threaded; needs multiple processes plus load balancing to avoid being a single point of failure | Part of the instance |
| Audit trail | Sits outside AlloyDB, so pgAudit records the pooler rather than the true client | Not applicable |
| Public IP exposure | Possible to misconfigure | Structurally impossible — unsupported on public IP |

The audit point deserves emphasis for a security audience. When an external
pooler multiplexes many application users onto a few database connections, the
identity that reaches PostgreSQL is the pooler's, not the end user's. That
weakens exactly the attribution that
[audit-logging-and-siem.md](../../docs/04-operations/audit-logging-and-siem.md)
depends on.

The public IP point is worth stating plainly too: because managed connection
pooling cannot be used over a public IP, adopting it reinforces the
private-only networking posture described in
[security-hardening.md](../../docs/04-operations/security-hardening.md).

---

## Related

- [app-side-pool-sizing.md](app-side-pool-sizing.md) — sizing the pool inside
  your application, which complements rather than replaces this
- [scaling-playbook.md](../../docs/04-operations/scaling-playbook.md) — when
  pooling is the right answer versus scaling up or out
- [Managed connection pooling](https://cloud.google.com/alloydb/docs/configure-managed-connection-pooling)
  — official documentation

---

*Last verified: 2026-09-22 against the AlloyDB documentation and provider
google v8.3.0. Defaults and limits are quoted from
https://cloud.google.com/alloydb/docs/configure-managed-connection-pooling.*
