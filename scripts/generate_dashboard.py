#!/usr/bin/env python3
"""
Generate the AlloyDB Cloud Monitoring dashboard.

Building the JSON with a script rather than by hand because:
  * a hand-written 600-line dashboard JSON is unreviewable and drifts
  * every metric type is declared once, in METRICS, so a typo is a one-line fix
  * it emits BOTH the Terraform template (.tftpl) and a standalone .json for
    console import, guaranteeing the two never diverge

All metric types used here were confirmed against the Cloud Monitoring
metricDescriptors API on 2026-09-22.

Usage:
    python3 scripts/generate_dashboard.py
"""

import json
import os

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Placeholder substituted by Terraform's templatefile(). For the standalone
# JSON it is replaced with a literal cluster id the user edits.
CLUSTER_VAR = "${cluster_id}"

INSTANCE = 'resource.type="alloydb.googleapis.com/Instance"'
CLUSTER = 'resource.type="alloydb.googleapis.com/Cluster"'


def cluster_filter(resource: str, cluster: str) -> str:
    return f'{resource} resource.labels.cluster_id="{cluster}"'


def xy(title, filt, aligner="ALIGN_MEAN", reducer=None, group_by=None,
       axis_label="", scale="LINEAR", thresholds=None, plot="LINE"):
    """One time-series chart widget."""
    agg = {"alignmentPeriod": "60s", "perSeriesAligner": aligner}
    if reducer:
        agg["crossSeriesReducer"] = reducer
    if group_by:
        agg["groupByFields"] = group_by

    widget = {
        "title": title,
        "xyChart": {
            "chartOptions": {"mode": "COLOR"},
            "dataSets": [{
                "plotType": plot,
                "targetAxis": "Y1",
                "timeSeriesQuery": {
                    "timeSeriesFilter": {
                        "filter": filt,
                        "aggregation": agg,
                    }
                },
            }],
            "yAxis": {"label": axis_label, "scale": scale},
        },
    }
    if thresholds:
        widget["xyChart"]["thresholds"] = thresholds
    return widget


def ratio(title, numerator, denominator, axis_label="", thresholds=None):
    """A ratio chart, e.g. connections / connections_limit."""
    agg = {"alignmentPeriod": "60s", "perSeriesAligner": "ALIGN_MEAN"}
    widget = {
        "title": title,
        "xyChart": {
            "chartOptions": {"mode": "COLOR"},
            "dataSets": [{
                "plotType": "LINE",
                "targetAxis": "Y1",
                "timeSeriesQuery": {
                    "timeSeriesFilterRatio": {
                        "numerator": {"filter": numerator, "aggregation": agg},
                        "denominator": {"filter": denominator, "aggregation": dict(agg)},
                    }
                },
            }],
            "yAxis": {"label": axis_label, "scale": "LINEAR"},
        },
    }
    if thresholds:
        widget["xyChart"]["thresholds"] = thresholds
    return widget


def text(title, content):
    return {
        "title": title,
        "text": {"content": content, "format": "MARKDOWN"},
    }


def metric(name, resource=INSTANCE, cluster=CLUSTER_VAR, extra=""):
    f = f'metric.type="alloydb.googleapis.com/{name}" {cluster_filter(resource, cluster)}'
    return f + (" " + extra if extra else "")


def build(cluster=CLUSTER_VAR, display_name="AlloyDB Overview"):
    widgets = [
        text(
            "How to read this dashboard",
            "**Saturation first, then latency, then correctness.**\n\n"
            "CPU and connection charts tell you if you are out of capacity. "
            "Query Insights tells you where the time goes. The vacuum and "
            "replication charts are slow-burn risks that will not show up as "
            "latency until it is too late.\n\n"
            "Utilisation metrics are fractions (0-1), not percentages.",
        ),

        # ---- Saturation ----
        xy(
            "CPU utilisation (max across nodes)",
            metric("instance/cpu/maximum_utilization", cluster=cluster),
            reducer="REDUCE_MAX",
            group_by=["resource.label.instance_id"],
            axis_label="fraction (0-1)",
            thresholds=[{"value": 0.85, "color": "YELLOW", "direction": "ABOVE"}],
        ),
        xy(
            "CPU utilisation (average across nodes)",
            metric("instance/cpu/average_utilization", cluster=cluster),
            reducer="REDUCE_MEAN",
            group_by=["resource.label.instance_id"],
            axis_label="fraction (0-1)",
        ),
        ratio(
            "Connection utilisation (used / max_connections)",
            metric("instance/postgres/total_connections", cluster=cluster),
            metric("instance/postgres/connections_limit", cluster=cluster),
            axis_label="fraction (0-1)",
            thresholds=[{"value": 0.8, "color": "YELLOW", "direction": "ABOVE"}],
        ),
        xy(
            "Connections by state",
            metric("instance/postgresql/backends_by_state", cluster=cluster),
            reducer="REDUCE_SUM",
            group_by=["metric.label.state"],
            axis_label="connections",
            plot="STACKED_AREA",
        ),
        xy(
            "Available memory (minimum across nodes)",
            metric("instance/memory/min_available_memory", cluster=cluster),
            aligner="ALIGN_MIN",
            reducer="REDUCE_MIN",
            group_by=["resource.label.instance_id"],
            axis_label="bytes",
        ),

        # ---- Throughput ----
        xy(
            "Transactions per second",
            metric("instance/postgres/transaction_count", cluster=cluster),
            aligner="ALIGN_RATE",
            reducer="REDUCE_SUM",
            group_by=["resource.label.instance_id"],
            axis_label="tps",
        ),
        xy(
            "Query latency distribution (p99)",
            metric("database/postgresql/insights/aggregate/latencies",
                   resource=INSTANCE, cluster=cluster),
            aligner="ALIGN_PERCENTILE_99",
            axis_label="microseconds",
        ),
        xy(
            "Database load by wait time",
            metric("database/postgresql/insights/aggregate/lock_time", cluster=cluster),
            aligner="ALIGN_RATE",
            reducer="REDUCE_SUM",
            axis_label="lock time (us/s)",
        ),

        # ---- Cache and IO ----
        xy(
            "Buffer cache blocks read from storage",
            metric("instance/postgresql/blks_read", cluster=cluster),
            aligner="ALIGN_RATE",
            reducer="REDUCE_SUM",
            axis_label="blocks/s",
        ),
        xy(
            "Ultra-fast cache hit rate",
            metric("instance/postgres/ultrafastcache_hitrate", cluster=cluster),
            axis_label="fraction (0-1)",
        ),
        xy(
            "Temp bytes written (work_mem spills)",
            metric("instance/postgresql/temp_bytes_written_count", cluster=cluster),
            aligner="ALIGN_RATE",
            reducer="REDUCE_SUM",
            axis_label="bytes/s",
        ),

        # ---- Correctness / slow-burn risks ----
        xy(
            "Transaction ID utilisation (wraparound risk)",
            metric("database/postgresql/vacuum/transaction_id_utilization", cluster=cluster),
            aligner="ALIGN_MAX",
            axis_label="fraction (0-1)",
            thresholds=[
                {"value": 0.5, "color": "YELLOW", "direction": "ABOVE"},
                {"value": 0.8, "color": "RED", "direction": "ABOVE"},
            ],
        ),
        xy(
            "Replication lag (read pools)",
            metric("instance/postgres/replication/maximum_lag", cluster=cluster),
            aligner="ALIGN_MAX",
            axis_label="milliseconds",
        ),
        xy(
            "Deadlocks",
            metric("instance/postgresql/deadlock_count", cluster=cluster),
            aligner="ALIGN_RATE",
            reducer="REDUCE_SUM",
            axis_label="deadlocks/s",
        ),
        xy(
            "Nodes up / down",
            metric("instance/postgres/instances", cluster=cluster),
            reducer="REDUCE_SUM",
            group_by=["metric.label.status"],
            axis_label="nodes",
            plot="STACKED_BAR",
        ),

        # ---- Storage ----
        ratio(
            "Storage quota utilisation",
            metric("quota/storage_usage_per_cluster/usage", resource=CLUSTER, cluster=cluster),
            metric("quota/storage_usage_per_cluster/limit", resource=CLUSTER, cluster=cluster),
            axis_label="fraction (0-1)",
            thresholds=[{"value": 0.8, "color": "YELLOW", "direction": "ABOVE"}],
        ),
        xy(
            "Cluster storage used",
            metric("cluster/storage/usage", resource=CLUSTER, cluster=cluster),
            axis_label="bytes",
        ),

        # ---- Connection pooling ----
        xy(
            "Managed pool: client wait time",
            metric("database/conn_pool/client_connections_avg_wait_time", cluster=cluster),
            reducer="REDUCE_MAX",
            axis_label="microseconds",
        ),
        xy(
            "Managed pool: client vs server connections",
            metric("database/conn_pool/client_connections", cluster=cluster),
            reducer="REDUCE_SUM",
            group_by=["metric.label.status"],
            axis_label="connections",
        ),
    ]

    return {
        "displayName": display_name,
        # mosaicLayout with a 12-column grid; two charts per row.
        "mosaicLayout": {
            "columns": 12,
            "tiles": _layout(widgets),
        },
    }


def _layout(widgets):
    """Place the intro text full width, then two charts per row."""
    tiles = []
    y = 0
    # Intro banner: full width, short.
    tiles.append({"width": 12, "height": 3, "xPos": 0, "yPos": y, "widget": widgets[0]})
    y += 3
    for i, w in enumerate(widgets[1:]):
        x = 0 if i % 2 == 0 else 6
        tiles.append({"width": 6, "height": 4, "xPos": x, "yPos": y, "widget": w})
        if i % 2 == 1:
            y += 4
    if len(widgets[1:]) % 2 == 1:
        y += 4
    return tiles


def main():
    # 1. Terraform template - keeps ${cluster_id} and ${display_name} as
    #    templatefile() placeholders.
    tf = build(cluster=CLUSTER_VAR, display_name="__DISPLAY_NAME__")
    tftpl = json.dumps(tf, indent=2)
    tftpl = tftpl.replace('"__DISPLAY_NAME__"', '"${display_name}"')
    tftpl_path = os.path.join(
        REPO, "terraform", "modules", "observability", "dashboard.json.tftpl")
    with open(tftpl_path, "w") as f:
        f.write(tftpl + "\n")

    # 2. Standalone JSON for console / gcloud import.
    standalone = build(cluster="REPLACE_WITH_YOUR_CLUSTER_ID",
                       display_name="AlloyDB Overview")
    json_path = os.path.join(
        REPO, "monitoring", "dashboards", "alloydb-overview.json")
    with open(json_path, "w") as f:
        f.write(json.dumps(standalone, indent=2) + "\n")

    print(f"wrote {tftpl_path}")
    print(f"wrote {json_path}")
    print(f"{len(tf['mosaicLayout']['tiles'])} tiles")


if __name__ == "__main__":
    main()
