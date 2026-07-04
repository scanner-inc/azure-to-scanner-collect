output "s3_bucket_name" {
  value       = local.target_bucket_name
  description = "Name of the S3 target bucket"
}

output "eventhub_namespace_name" {
  value       = azurerm_eventhub_namespace.this.name
  description = "Name of the Event Hub namespace receiving Activity Logs"
}

output "eventhub_name" {
  value       = azurerm_eventhub.this.name
  description = "Name of the Event Hub receiving Activity Logs"
}

output "eventhub_send_connection_string" {
  value       = azurerm_eventhub_namespace_authorization_rule.diagnostic_sender.primary_connection_string
  description = "Send-capable connection string for the Event Hub namespace (used by tests to inject synthetic events)"
  sensitive   = true
}

output "diagnostic_setting_name" {
  value       = azurerm_monitor_diagnostic_setting.activity_logs.name
  description = "Name of the subscription diagnostic setting"
}

output "staging_storage_account_name" {
  value       = azurerm_storage_account.staging.name
  description = "Storage account holding batched staging blobs"
}

output "staging_container_name" {
  value       = azurerm_storage_container.staging.name
  description = "Container holding batched staging blobs (drained by the transfer function)"
}

output "function_app_name" {
  value       = azurerm_linux_function_app.this.name
  description = "Function app hosting the batch/transfer/sweep functions"
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

output "event_subscription_name" {
  value       = azurerm_eventgrid_system_topic_event_subscription.transfer.name
  description = "Event Grid subscription delivering staging BlobCreated events to the transfer function"
}

output "test_instructions" {
  value = <<-EOT

  Activity Logs pipeline deployed successfully!

  Architecture:
  Subscription Activity Logs → Event Hub → batch function (gzip NDJSON) → staging container
                                             → transfer function → S3 (staging blob deleted)
                                             → sweep function retries stale staging blobs

  To verify the setup:

  1. Generate an Activity Log entry (any ARM write works), e.g.:
     az group update --name ${local.resource_group_name} --set tags.test=activity-log-test

  2. Check function logs:
     az webapp log tail --name ${local.function_app_name} --resource-group ${local.resource_group_name}

  3. Verify objects appear in S3 (expect 2-5 min end to end):
     aws s3 ls s3://${local.target_bucket_name}/${trim(var.log_prefix, "/")}/ --recursive | tail -20

  Latency: Activity Log delivery to Event Hub is typically 1-5 minutes;
  batching and transfer add seconds.
${!local.using_existing_bucket && var.s3_expiration_days > 0 ? "\n  Lifecycle: Objects in the S3 bucket expire after ${var.s3_expiration_days} days.\n" : ""}${local.scanner_sns_provided ? "\n  Scanner Integration:\n  You can now link your AWS bucket '${local.target_bucket_name}' in the scanner AWS account settings.\n" : ""}
  EOT
}
