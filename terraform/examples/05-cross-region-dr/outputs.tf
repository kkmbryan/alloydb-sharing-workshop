output "primary_cluster_name" {
  description = "Full resource name of the primary cluster."
  value       = module.alloydb_primary.cluster_name
}

output "secondary_cluster_name" {
  description = "Full resource name of the DR secondary cluster."
  value       = module.alloydb_secondary.cluster_name
}

output "primary_psc_endpoint_ip" {
  description = "PSC endpoint IP in the primary region. All writes go here today."
  value       = module.psc_endpoint_primary.ip_address
}

output "secondary_psc_endpoint_ip" {
  description = <<-EOT
    PSC endpoint IP in the DR region. Read-only until the cluster is promoted.

    This exists before the incident on purpose. Creating an endpoint while a
    region is down, with Terraform possibly unusable, is not a plan.
  EOT
  value       = module.psc_endpoint_secondary.ip_address
}

output "psc_dns_records_required" {
  description = <<-EOT
    Hostnames that must resolve, and the addresses they must resolve to.

    If create_psc_dns is false, create both records wherever your DNS is
    managed - the DR one included. Creating it only at failover time adds
    propagation delay to your RTO.
  EOT
  value = {
    (coalesce(module.alloydb_primary.psc_dns_name, "primary-pending"))     = module.psc_endpoint_primary.ip_address
    (coalesce(module.alloydb_secondary.psc_dns_name, "secondary-pending")) = module.psc_endpoint_secondary.ip_address
  }
}

output "total_vcpu_quota" {
  description = "vCPU quota consumed per region. Each region has its own quota."
  value = {
    (var.primary_region)   = module.alloydb_primary.estimated_vcpu_quota_consumed
    (var.secondary_region) = module.alloydb_secondary.estimated_vcpu_quota_consumed
  }
}

output "dr_runbook" {
  description = "Failover procedures. Rehearse these before you need them."
  value       = <<-EOT

    ========================================================================
    PLANNED failover - switchover (zero data loss)
    ========================================================================
    Use for: DR drills, region migration, planned maintenance.
    Requires: BOTH clusters healthy and reachable.

    The primary is quiesced, outstanding changes are drained to the secondary,
    then the roles reverse. Replication continues in the opposite direction,
    so it is reversible - run it again to switch back.

      gcloud alloydb clusters switchover ${module.alloydb_secondary.cluster_name} \
        --region=${var.secondary_region}

    ========================================================================
    UNPLANNED failover - promote (non-zero data loss)
    ========================================================================
    Use for: the primary region is gone or unreachable.

    Data loss is bounded by the replication lag at the moment of failure -
    which is exactly what the replication lag alert measures. Promotion
    BREAKS the replication link permanently: the secondary becomes an
    independent read-write cluster, and re-establishing DR afterwards means
    building a new secondary from the new primary.

      gcloud alloydb clusters promote ${module.alloydb_secondary.cluster_name} \
        --region=${var.secondary_region}

    ========================================================================
    After ANY failover
    ========================================================================
    1. Repoint applications to the DR endpoint. AlloyDB does not move the
       endpoint for you, and neither does PSC: an endpoint is regional and
       targets one service attachment, so the DR region has its own address:

         today       ${module.psc_endpoint_primary.ip_address}   (${var.primary_region})
         after promote ${module.psc_endpoint_secondary.ip_address}   (${var.secondary_region})

       Whatever performs that switch - a CNAME you repoint, application
       config, service discovery - is YOUR RTO bottleneck, not AlloyDB's.
       Automate it, keep the TTL short, and rehearse it. A DR drill that skips
       this step has tested the easy half.
    2. Recreate read pools. They do not carry across, and on PSC each new pool
       also needs its own endpoint and DNS record.
    3. Re-establish backup policy and monitoring on the new primary.
    4. Update Terraform: after a promote, cluster_type has changed underneath
       you. The module sets lifecycle.ignore_changes on instance_type to stop
       Terraform trying to recreate the instance, but the configuration still
       needs reconciling with reality.

    ========================================================================
    What this does NOT protect against
    ========================================================================
    Logical corruption replicates. A bad migration or a malicious DELETE
    reaches the secondary in seconds. For that, use point-in-time recovery on
    the primary - configured here with a ${local.pitr_window_days}-day window:

      gcloud alloydb clusters restore RESTORED_CLUSTER \
        --region=${var.primary_region} \
        --source-cluster=${module.alloydb_primary.cluster_name} \
        --point-in-time=TIMESTAMP_BEFORE_THE_INCIDENT

    Restores create a NEW cluster; they do not restore in place.
  EOT
}
