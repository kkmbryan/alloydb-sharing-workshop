# Application-Side Connection Pool Sizing

> The pool inside your application is the first line of defence for AlloyDB.
> Getting it wrong is the most common cause of "the database is down" incidents
> that turn out to be an application problem.

## The one formula you need

For a CPU-bound OLTP workload, total **concurrent server connections** across
all application instances should land around:

```
connections  =  (2 to 4)  x  vCPU count of the AlloyDB primary
```

This is deliberately small, and it surprises people. A database can only
actually execute as many queries at once as it has cores. Extra connections do
not add throughput — they add context switching, lock contention and memory
pressure, which *reduces* it. The classic shape of the curve:

```
throughput
    |            ....----....
    |        ...'            '''...
    |     ..'                        '''....
    |   .'                                   '''....
    | .'
    +--------------------------------------------------> connections
      ^                ^
      too few      optimal (~2-4x vCPU)      too many: throughput DROPS
```

If your workload waits on network or disk more than CPU, you can go higher —
but measure it, do not assume it.

## The capacity arithmetic

Before you deploy, do this sum. It is the check almost nobody does, and it is
why services fall over at 3am during a rolling restart.

```
  (max pool size per app instance)
x (number of app instances at maximum autoscale)
+ (background workers / cron jobs / batch importers)
+ (migration tooling running during a deploy)
+ (analytics and BI tools)
+ (monitoring agents)
+ (human operators with a psql session open)
--------------------------------------------------------
= peak connections   ->   must be < AlloyDB max_connections
```

Two traps hide in that sum:

1. **Autoscale maximum, not current count.** A service running 4 pods today
   with `maxReplicas: 100` is a service that can open 25x more connections than
   you observed in testing.
2. **Deploy-time doubling.** During a rolling deploy both the old and new
   ReplicaSets are alive. Budget for 2x your steady-state instance count, or
   use a surge setting that caps it.

If the sum does not fit, the answer is **a pooler, not a bigger
`max_connections`.** See [managed-connection-pooling.md](./managed-connection-pooling.md).

## Settings that matter, by language

The names differ but every mature pool has the same five knobs. Set all five —
the defaults are almost always wrong for a cloud database.

| Concept | Why it matters | Typical value |
| --- | --- | --- |
| **max pool size** | The hard cap. This is the number in the arithmetic above. | 2–4x vCPU ÷ instances |
| **min idle / min size** | Keeps connections warm so a spike does not pay TLS+auth setup. Set equal to max for steady workloads to get a fixed-size pool. | = max, for predictable load |
| **connection timeout** | How long a thread waits for a connection before erroring. Must be **shorter** than your HTTP request timeout, or you convert a fast failure into an upstream 504. | 2–5 s |
| **max lifetime** | Forces periodic reconnection. Essential on AlloyDB: after a failover or a machine-type change the old backend is gone, and this is what rotates the pool onto the new one. Set it **below** any infrastructure idle timeout. | 15–30 min |
| **idle timeout** | Releases connections during quiet periods. | 5–10 min |

### Java — HikariCP

```properties
# The hard cap. Count it against AlloyDB max_connections across ALL pods.
maximumPoolSize=20

# A fixed-size pool. HikariCP's own guidance: for a server-side application
# with a steady load, min == max gives the most predictable latency.
minimumIdle=20

# Fail fast. Must be < the application's own request timeout.
connectionTimeout=3000

# Rotate connections so the pool follows AlloyDB through a failover.
# Keep this a few seconds below any load balancer / firewall idle timeout.
maxLifetime=1800000

idleTimeout=600000

# Cheap liveness check on borrow; 250ms is plenty on a private IP.
validationTimeout=250

# Log a stack trace when a connection is held far too long - this is how you
# find the code path that leaks connections.
leakDetectionThreshold=60000
```

> [!WARNING]
> The HikariCP default `maximumPoolSize` is **10 per application instance**.
> Thirty pods silently means 300 connections.

### Go — pgxpool

```go
cfg, err := pgxpool.ParseConfig(dsn)
if err != nil {
    return nil, err
}

// The hard cap for THIS process.
cfg.MaxConns = 20

// Keep connections warm.
cfg.MinConns = 5

// Rotate connections so the pool follows AlloyDB through a failover.
cfg.MaxConnLifetime = 30 * time.Minute

// Jitter prevents every connection in every pod reconnecting simultaneously
// (a thundering herd that looks exactly like an outage).
cfg.MaxConnLifetimeJitter = 5 * time.Minute

cfg.MaxConnIdleTime = 10 * time.Minute
cfg.HealthCheckPeriod = 1 * time.Minute

// Identify the workload in pg_stat_activity - makes the connection-census
// query in monitoring/sql/02_connections_and_locks.sql actually useful.
cfg.ConnConfig.RuntimeParams["application_name"] = "checkout-api"
```

> [!TIP]
> `database/sql` users: the default `MaxIdleConns` is **2**. If `MaxOpenConns`
> is 20 and `MaxIdleConns` is 2, you churn 18 connections continuously — full
> TCP + TLS + auth on almost every query. Always set
> `SetMaxIdleConns == SetMaxOpenConns`.

### Python — SQLAlchemy

```python
engine = create_engine(
    url,
    # Persistent connections.
    pool_size=10,
    # Burst capacity above pool_size. These are created and destroyed on
    # demand, so the real cap is pool_size + max_overflow = 15. Budget for
    # the SUM, not for pool_size.
    max_overflow=5,
    # Fail fast rather than queueing forever.
    pool_timeout=3,
    # Rotate connections so the pool follows AlloyDB through a failover.
    pool_recycle=1800,
    # Validate on checkout; avoids handing out a connection killed by a
    # failover. Costs one round trip.
    pool_pre_ping=True,
    connect_args={"application_name": "checkout-api"},
)
```

> [!IMPORTANT]
> Gunicorn/uWSGI **fork** workers. Each worker process gets its own pool, so
> the real connection count is `workers x (pool_size + max_overflow)`. A
> 4-worker Gunicorn with the config above uses 60 connections, not 15. Also
> dispose the engine in a post-fork hook — a pool inherited across `fork()`
> shares sockets between processes and corrupts the protocol stream.

### Node.js — node-postgres

```js
const pool = new Pool({
  max: 10,                        // hard cap for this process
  min: 2,
  connectionTimeoutMillis: 3000,  // fail fast
  idleTimeoutMillis: 600000,
  maxLifetimeSeconds: 1800,       // follow AlloyDB through a failover
  application_name: 'checkout-api',
});

// A pool error is emitted for idle clients killed server-side (e.g. by a
// failover). Without this handler Node crashes the process on an unhandled
// 'error' event.
pool.on('error', (err) => logger.error({ err }, 'idle client error'));
```

## Serverless is the exception

Cloud Run, Cloud Functions and Lambda break the model above: instance count is
elastic and can spike far beyond what you would provision.

- Keep the per-instance pool **very small** — 1 to 5.
- Set the maximum instance count on the service. This is your only real
  connection cap, so treat it as a database setting, not a compute setting.
- Reuse the pool across invocations by creating it in the global/module scope,
  never inside the request handler.
- Strongly prefer putting a pooler in front, so bursty instance churn does not
  translate directly into backend churn on AlloyDB.

## Verifying it in production

Run query **B** in
[02_connections_and_locks.sql](../../monitoring/sql/02_connections_and_locks.sql)
to get a census of connections grouped by `application_name` and `client_addr`.
This is why setting `application_name` in every pool config above matters: it
turns an anonymous wall of 400 connections into an actionable list of which
service is responsible for them.

Signals that the pool is **too small**: application-side "timeout acquiring
connection" errors while AlloyDB CPU is low.

Signals that the pool is **too large**: high AlloyDB CPU with low throughput,
many sessions in `LWLock` waits, or memory pressure on the instance.

---

*See also: [scaling-playbook.md](../../docs/scaling-playbook.md) ·
[sizing-guide.md](../../docs/sizing-guide.md)*
