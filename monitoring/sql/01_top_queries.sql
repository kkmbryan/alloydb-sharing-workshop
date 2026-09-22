-- ===========================================================================
-- 01_top_queries.sql
-- Find the queries that actually cost you money and latency.
-- ===========================================================================
--
-- Prerequisite: pg_stat_statements must be loaded. On AlloyDB it is enabled by
-- default; verify with:
--     SELECT * FROM pg_extension WHERE extname = 'pg_stat_statements';
-- If missing:
--     CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
--
-- Reading these results:
--   * Sort by total_exec_time first, NOT mean_exec_time. A 5 ms query run
--     2 million times is a bigger problem than a 9 s report run twice a day.
--   * Then look at the same list sorted by calls - that is your candidate list
--     for caching or batching at the application layer.
--   * hit_percent below ~95% on a hot query means the working set is spilling
--     out of the buffer cache: either the query is scanning too much, or the
--     instance is undersized for the working set.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- A. Top 20 queries by TOTAL time consumed (the real CPU hogs)
-- ---------------------------------------------------------------------------
SELECT
    substring(query, 1, 120)                        AS query_prefix,
    calls,
    round(total_exec_time::numeric, 1)              AS total_ms,
    round(mean_exec_time::numeric, 2)               AS mean_ms,
    round(stddev_exec_time::numeric, 2)             AS stddev_ms,
    rows,
    round(100.0 * total_exec_time
          / NULLIF(sum(total_exec_time) OVER (), 0), 1) AS pct_of_total,
    round(100.0 * shared_blks_hit
          / NULLIF(shared_blks_hit + shared_blks_read, 0), 1) AS cache_hit_pct
FROM pg_stat_statements
WHERE query NOT LIKE '%pg_stat_statements%'
ORDER BY total_exec_time DESC
LIMIT 20;


-- ---------------------------------------------------------------------------
-- B. Top 20 queries by CALL COUNT (candidates for app-side caching/batching)
-- ---------------------------------------------------------------------------
SELECT
    substring(query, 1, 120)            AS query_prefix,
    calls,
    round(mean_exec_time::numeric, 3)   AS mean_ms,
    round(total_exec_time::numeric, 1)  AS total_ms
FROM pg_stat_statements
WHERE query NOT LIKE '%pg_stat_statements%'
ORDER BY calls DESC
LIMIT 20;


-- ---------------------------------------------------------------------------
-- C. Most VARIABLE queries (high stddev = unpredictable p99, usually a bad
--    plan flip, parameter sniffing, or lock waiting)
-- ---------------------------------------------------------------------------
SELECT
    substring(query, 1, 120)            AS query_prefix,
    calls,
    round(mean_exec_time::numeric, 2)   AS mean_ms,
    round(stddev_exec_time::numeric, 2) AS stddev_ms,
    round(max_exec_time::numeric, 2)    AS max_ms
FROM pg_stat_statements
WHERE calls > 100
  AND query NOT LIKE '%pg_stat_statements%'
ORDER BY stddev_exec_time DESC
LIMIT 20;


-- ---------------------------------------------------------------------------
-- D. Queries doing the most physical I/O (candidates for the columnar engine,
--    better indexes, or a larger data cache)
-- ---------------------------------------------------------------------------
SELECT
    substring(query, 1, 120)                        AS query_prefix,
    calls,
    shared_blks_read                                AS blocks_read_from_disk,
    pg_size_pretty(shared_blks_read * 8192::bigint) AS bytes_read_from_disk,
    round(100.0 * shared_blks_hit
          / NULLIF(shared_blks_hit + shared_blks_read, 0), 1) AS cache_hit_pct
FROM pg_stat_statements
WHERE shared_blks_read > 0
ORDER BY shared_blks_read DESC
LIMIT 20;


-- ---------------------------------------------------------------------------
-- E. Queries spilling to temp files (work_mem is too small for these)
--    A high value here is the single best justification for raising work_mem.
-- ---------------------------------------------------------------------------
SELECT
    substring(query, 1, 120)                        AS query_prefix,
    calls,
    temp_blks_written,
    pg_size_pretty(temp_blks_written * 8192::bigint) AS temp_written,
    pg_size_pretty((temp_blks_written * 8192 / NULLIF(calls, 0))::bigint)
                                                    AS temp_per_call
FROM pg_stat_statements
WHERE temp_blks_written > 0
ORDER BY temp_blks_written DESC
LIMIT 20;


-- ---------------------------------------------------------------------------
-- Reset the statistics baseline (do this before a load test, then re-run A-E)
-- ---------------------------------------------------------------------------
-- SELECT pg_stat_statements_reset();
