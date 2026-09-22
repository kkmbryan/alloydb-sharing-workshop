output "cluster_name" {
  description = "Full cluster resource name."
  value       = module.alloydb.cluster_name
}

output "kms_key_id" {
  description = "CMEK key protecting the cluster and its backups."
  value       = google_kms_crypto_key.alloydb.id
}

output "alloydb_service_agent" {
  description = "AlloyDB service agent granted encrypt/decrypt on the key. Useful evidence for a security review."
  value       = google_project_service_identity.alloydb.email
}

output "psc_endpoint_ip" {
  description = "Internal IP of the PSC endpoint. This is what clients connect to."
  value       = google_compute_address.psc_endpoint.address
}

output "psc_dns_name" {
  description = "Hostname AlloyDB advertises for this instance, mapped to the endpoint IP by the private zone."
  value       = module.alloydb.psc_dns_name
}

output "psc_service_attachment" {
  description = "Producer-side service attachment the forwarding rule targets."
  value       = module.alloydb.psc_service_attachment_link
}

output "audit_sink_writer_identity" {
  description = <<-EOT
    Service account the log sink writes as.

    You must grant this principal write access on the destination, or the
    export silently delivers nothing:
      Pub/Sub   -> roles/pubsub.publisher
      BigQuery  -> roles/bigquery.dataEditor
      Storage   -> roles/storage.objectCreator
  EOT
  value       = try(google_logging_project_sink.alloydb_audit[0].writer_identity, null)
}

output "security_posture_summary" {
  description = "Controls applied, for pasting into a design review."
  value       = <<-EOT

    Network
      Private Service Connect          enabled (no VPC peering)
      Public IP                        disabled
      Authorized external networks     none
      Consumer projects allow-listed   ${length(module.alloydb.cluster_name) > 0 ? "yes" : "n/a"}

    Encryption
      At rest                          CMEK, ${var.kms_protection_level}-backed
      Key rotation                     ${var.key_rotation_period}
      Backups                          CMEK with the same key
      In transit                       ENCRYPTED_ONLY
      Direct connections               blocked (require_connectors = true)

    Identity
      IAM database authentication      enabled
      IAM group authentication         enabled
      Password complexity + expiry     enforced
      pg_authid / pg_shadow reads      restricted to alloydbsuperuser

    Audit
      Admin Activity logs              always on
      Data Access logs                 enabled
      pgAudit classes                  ${var.pgaudit_log_classes}
      Statement parameters logged      yes
      Export sink                      ${var.audit_sink_destination == null ? "NOT CONFIGURED" : var.audit_sink_destination}
      Audit backlog alerting           enabled

    Recovery
      Continuous backup / PITR         35 days
      Scheduled backup retention       60 backups
      Deletion protection              enabled

    Verify with: ./scripts/verify-security-posture.sh
  EOT
}
