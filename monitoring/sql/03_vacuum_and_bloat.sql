-- ===========================================================================
-- 03_vacuum_and_bloat.sql
-- Transaction ID wraparound and table bloat: the two silent killers.
-- ===========================================================================
--
-- Run query A weekly, and alert on it. Transaction ID wraparound is the single
-- most dangerous failure mode in PostgreSQL: if the age of a database reaches
-- the wraparound limit the database shuts down and refuses writes until an
-- offline VACUUM completes. AlloyDB's autovacuum will normally prevent this,
-- but a long-lived idle-in-transaction session or an abandoned replication
-- slot can stall it indefinitely.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- A. Transaction ID wraparound headroom.
--    Warn above 0.2, page above 0.4. The metric is a fraction (0-1), not a
--    percentage; see docs/monitoring-metrics.md.
-- ---------------------------------------------------------------------------
SELECT
    datname                                              AS database,
    age(datfrozenxid)                                    AS xid_age,
    current_setting('autovacuum_freeze_max_age')::bigint AS autovacuum_trigger,
    2147483647                                           AS hard_wraparound_limit,
    round(100.0 * age(datfrozenxid) / 2147483647, 2)     AS pct_to_wraparound
FROM pg_database
WHERE datallowconn
ORDER BY age(datfrozenxid) DESC;


-- ---------------------------------------------------------------------------
-- B. The same, per table - finds the ONE table that is blocking freezing.
-- ---------------------------------------------------------------------------
SELECT
    n.nspname                                AS schema,
    c.relname                                AS table_name,
    age(c.relfrozenxid)                      AS xid_age,
    pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size,
    s.last_autovacuum,
    s.last_vacuum
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_stat_all_tables s ON s.relid = c.oid
WHERE c.relkind IN ('r', 'm')
  AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
ORDER BY age(c.relfrozenxid) DESC
LIMIT 25;


-- ---------------------------------------------------------------------------
-- C. What is holding back the vacuum horizon?
--    Any of these three will stop autovacuum from reclaiming dead rows, no
--    matter how aggressively you tune it.
-- ---------------------------------------------------------------------------
-- C1: long-running transactions
SELECT 'long_running_txn' AS blocker_type,
       pid::text          AS identifier,
       (now() - xact_start)::text AS age,
       coalesce(substring(query, 1, 80), '') AS detail
FROM pg_stat_activity
WHERE xact_start IS NOT NULL
  AND now() - xact_start > interval '5 minutes'

UNION ALL

-- C2: abandoned replication slots (inactive slots retain WAL forever)
SELECT 'replication_slot',
       slot_name,
       coalesce(active::text, 'unknown'),
       'active=' || active::text
FROM pg_replication_slots
WHERE NOT active

UNION ALL

-- C3: prepared transactions that were never committed or rolled back
SELECT 'prepared_transaction',
       gid,
       (now() - prepared)::text,
       'owner=' || owner
FROM pg_prepared_xacts

ORDER BY 1, 3 DESC;


-- ---------------------------------------------------------------------------
-- D. Dead tuple accumulation - which tables need vacuum attention?
--    dead_pct consistently above 20% on a large table means autovacuum is not
--    keeping up; lower autovacuum_vacuum_scale_factor for that table:
--      ALTER TABLE x SET (autovacuum_vacuum_scale_factor = 0.02);
-- ---------------------------------------------------------------------------
SELECT
    schemaname                                       AS schema,
    relname                                          AS table_name,
    n_live_tup                                       AS live_rows,
    n_dead_tup                                       AS dead_rows,
    round(100.0 * n_dead_tup
          / NULLIF(n_live_tup + n_dead_tup, 0), 1)   AS dead_pct,
    pg_size_pretty(pg_total_relation_size(relid))    AS total_size,
    last_autovacuum,
    last_autoanalyze,
    autovacuum_count,
    n_mod_since_analyze
FROM pg_stat_user_tables
WHERE n_dead_tup > 1000
ORDER BY n_dead_tup DESC
LIMIT 25;


-- ---------------------------------------------------------------------------
-- E. Currently running autovacuum workers.
--    If this is always full (3 workers by default) autovacuum is saturated.
-- ---------------------------------------------------------------------------
SELECT
    p.pid,
    now() - a.xact_start        AS running_for,
    p.datname,
    p.relid::regclass           AS table_name,
    p.phase,
    p.heap_blks_total,
    p.heap_blks_scanned,
    round(100.0 * p.heap_blks_scanned
          / NULLIF(p.heap_blks_total, 0), 1) AS pct_scanned
FROM pg_stat_progress_vacuum p
JOIN pg_stat_activity a ON a.pid = p.pid
ORDER BY running_for DESC;


-- ---------------------------------------------------------------------------
-- F. Table and index bloat estimate.
--    This is an ESTIMATE based on statistics, not an exact measurement.
--    Requires pgstattuple for exact numbers:
--      CREATE EXTENSION IF NOT EXISTS pgstattuple;
--      SELECT * FROM pgstattuple('schema.table');
--    pgstattuple does a full scan - do not run it on a huge table in peak hours.
-- ---------------------------------------------------------------------------
SELECT
    schemaname                                    AS schema,
    relname                                       AS table_name,
    pg_size_pretty(pg_relation_size(relid))       AS heap_size,
    pg_size_pretty(pg_indexes_size(relid))        AS index_size,
    pg_size_pretty(pg_total_relation_size(relid)) AS total_size,
    n_dead_tup,
    round(100.0 * n_dead_tup
          / NULLIF(n_live_tup + n_dead_tup, 0), 1) AS est_bloat_pct
FROM pg_stat_user_tables
ORDER BY pg_total_relation_size(relid) DESC
LIMIT 25;


-- ---------------------------------------------------------------------------
-- G. Unused indexes - they cost write throughput, storage and vacuum time.
--    Verify against a read replica's stats too before dropping: an index used
--    only by a monthly report will look unused on any given day.
-- ---------------------------------------------------------------------------
SELECT
    s.schemaname                                  AS schema,
    s.relname                                     AS table_name,
    s.indexrelname                                AS index_name,
    s.idx_scan                                    AS times_used,
    pg_size_pretty(pg_relation_size(s.indexrelid)) AS index_size
FROM pg_stat_user_indexes s
JOIN pg_index i ON i.indexrelid = s.indexrelid
WHERE s.idx_scan = 0
  AND NOT i.indisunique
  AND NOT i.indisprimary
ORDER BY pg_relation_size(s.indexrelid) DESC;
