output "source_storage_account_name" {
  value       = data.azurerm_storage_account.source.name
  description = "Name of the monitored source storage account"
}

output "source_container_name" {
  value       = var.source_container_name
  description = "Name of the monitored source container"
}

output "s3_bucket_name" {
  value       = local.target_bucket_name
  description = "Name of the S3 target bucket"
}

output "function_app_name" {
  value       = azurerm_linux_function_app.this.name
  description = "Function app hosting the mirror function"
}

output "system_topic_name" {
  value       = local.system_topic_name_effective
  description = "Event Grid system topic on the source storage account"
}

output "event_subscription_names" {
  value       = [for sub in azurerm_eventgrid_system_topic_event_subscription.mirror : sub.name]
  description = "Event Grid subscriptions delivering BlobCreated events to the mirror function (one per key prefix)"
}

output "dlq_storage_account_name" {
  value       = azurerm_storage_account.function_backing.name
  description = "Storage account holding the dead-letter container"
}

output "dlq_container_name" {
  value       = azurerm_storage_container.dlq.name
  description = "Container retaining dead-lettered events for inspection/replay"
}

output "alert_name" {
  value       = var.create_system_topic ? azurerm_monitor_metric_alert.dead_letter_alert[0].name : ""
  description = "Metric alert that fires when events are dead-lettered"
}

output "managed_identity_principal_id" {
  value       = azurerm_user_assigned_identity.this.principal_id
  description = "Managed identity principal id (pinned as sub in the AWS trust policy)"
}

output "managed_identity_client_id" {
  value       = azurerm_user_assigned_identity.this.client_id
  description = "Managed identity client id"
}

output "aws_role_arn" {
  value       = aws_iam_role.s3_writer_role.arn
  description = "ARN of the AWS IAM role the pipeline assumes"
}

output "test_instructions" {
  value = <<-EOT

  Blob container mirror pipeline deployed successfully!

  Architecture:
  Blob Container (existing) → Event Grid (BlobCreated) → Function (filter + copy) → S3
                                ↳ retries with backoff, dead-letters after ${var.max_delivery_attempts} attempts

  To verify the setup:

  1. Upload a test blob that passes your key filters:
     echo '{"test": true}' | az storage blob upload \
       --account-name ${data.azurerm_storage_account.source.name} \
       --container-name ${var.source_container_name} \
       --name ${length(var.key_prefixes) > 0 ? var.key_prefixes[0] : ""}mirror-test-$(date +%s).json \
       --data @- --auth-mode login

  2. Check mirror function logs:
     az webapp log tail --name ${local.function_app_name} --resource-group ${local.resource_group_name}

  3. Verify the blob appears in S3 (source blob stays in Azure):
     aws s3 ls s3://${local.target_bucket_name}/${var.s3_key_prefix != "" ? "${trim(var.s3_key_prefix, "/")}/" : ""} --recursive | head -20

  4. Inspect the dead-letter container (blobs that repeatedly failed to copy;
     an alert fires if anything lands here):
     az storage blob list --account-name ${azurerm_storage_account.function_backing.name} \
       --container-name ${azurerm_storage_container.dlq.name} -o table --auth-mode login

  Latency: New blobs should appear in S3 within seconds to ~1 minute.
${!local.using_existing_bucket && var.s3_expiration_days > 0 ? "\n  Lifecycle: Objects in the S3 bucket expire after ${var.s3_expiration_days} days (originals remain in Azure).\n" : ""}${local.scanner_sns_provided ? "\n  Scanner Integration:\n  You can now link your AWS bucket '${local.target_bucket_name}' in the scanner AWS account settings.\n" : ""}
  EOT
}
