-- ===========================================================================
-- 02_connections_and_locks.sql
-- Answer "why is the database not responding right now?"
-- ===========================================================================
--
-- Run these in order during an incident. Query A tells you if you are out of
-- connections; B tells you what those connections are doing; C tells you who
-- is blocking whom; D finds the idle-in-transaction sessions that are the most
-- common root cause of both connection exhaustion and vacuum starvation.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- A. Connection budget: how close are we to max_connections?
--    AlloyDB derives max_connections from the instance machine shape. If
--    used_pct is regularly above ~80 you need a connection pooler, not a
--    bigger max_connections.
-- ---------------------------------------------------------------------------
SELECT
    current_setting('max_connections')::int                       AS max_connections,
    count(*)                                                      AS total,
    count(*) FILTER (WHERE state = 'active')                      AS active,
    count(*) FILTER (WHERE state = 'idle')                        AS idle,
    count(*) FILTER (WHERE state = 'idle in transaction')         AS idle_in_txn,
    count(*) FILTER (WHERE wait_event_type IS NOT NULL)           AS waiting,
    round(100.0 * count(*)
          / current_setting('max_connections')::int, 1)           AS used_pct
FROM pg_stat_activity;


-- ---------------------------------------------------------------------------
-- B. Where are the connections coming from, and what are they doing?
--    Use this to find the one misconfigured service holding 400 connections.
-- ---------------------------------------------------------------------------
SELECT
    coalesce(usename, '<none>')      AS username,
    coalesce(datname, '<none>')      AS database,
    coalesce(application_name, '<none>') AS application,
    client_addr,
    state,
    count(*)                         AS connections,
    max(now() - state_change)        AS longest_in_state
FROM pg_stat_activity
WHERE backend_type = 'client backend'
GROUP BY 1, 2, 3, 4, 5
ORDER BY connections DESC;


-- ---------------------------------------------------------------------------
-- C. Current wait events - the fastest way to classify a slowdown.
--    Lock          -> contention, see query D/E
--    IO / DataFileRead -> undersized cache or missing index
--    LWLock        -> internal contention, often too many connections
--    Client        -> the application is slow, not the database
-- ---------------------------------------------------------------------------
SELECT
    coalesce(wait_event_type, 'Running') AS wait_event_type,
    coalesce(wait_event, '-')            AS wait_event,
    count(*)                             AS sessions
FROM pg_stat_activity
WHERE state = 'active'
  AND backend_type = 'client backend'
GROUP BY 1, 2
ORDER BY sessions DESC;


-- ---------------------------------------------------------------------------
-- D. Blocking tree: who is blocking whom, right now.
--    The `blocking_*` columns identify the session you need to talk to (or
--    terminate). Always kill the BLOCKER, never the victim.
-- ---------------------------------------------------------------------------
SELECT
    blocked.pid                                   AS blocked_pid,
    blocked.usename                               AS blocked_user,
    now() - blocked.query_start                   AS blocked_for,
    substring(blocked.query, 1, 80)               AS blocked_query,
    blocking.pid                                  AS blocking_pid,
    blocking.usename                              AS blocking_user,
    blocking.state                                AS blocking_state,
    now() - blocking.state_change                 AS blocking_in_state_for,
    substring(blocking.query, 1, 80)              AS blocking_query
FROM pg_stat_activity AS blocked
JOIN LATERAL unnest(pg_blocking_pids(blocked.pid)) AS blocking_pid ON true
JOIN pg_stat_activity AS blocking ON blocking.pid = blocking_pid
WHERE cardinality(pg_blocking_pids(blocked.pid)) > 0
ORDER BY blocked_for DESC;


-- ---------------------------------------------------------------------------
-- E. Long-running and idle-in-transaction sessions.
--    'idle in transaction' sessions hold locks AND pin the vacuum horizon,
--    causing table bloat. Set idle_in_transaction_session_timeout to kill them
--    automatically - see config/database-flags/.
-- ---------------------------------------------------------------------------
SELECT
    pid,
    usename,
    application_name,
    client_addr,
    state,
    now() - xact_start                 AS transaction_age,
    now() - query_start                AS query_age,
    now() - state_change               AS time_in_state,
    wait_event_type,
    wait_event,
    substring(query, 1, 100)           AS query_prefix
FROM pg_stat_activity
WHERE backend_type = 'client backend'
  AND state <> 'idle'
  AND now() - xact_start > interval '30 seconds'
ORDER BY xact_start;


-- ---------------------------------------------------------------------------
-- F. Emergency: terminate a specific session.
--    pg_cancel_backend  -> cancels the running query, keeps the connection.
--    pg_terminate_backend -> drops the connection entirely, rolls back.
--    Always try cancel first.
-- ---------------------------------------------------------------------------
-- SELECT pg_cancel_backend(<pid>);
-- SELECT pg_terminate_backend(<pid>);
