# Everything the pytest driver needs, consumed via `terraform output -json`

output "run_suffix" {
  value = var.run_suffix
}

output "subscription_id" {
  value = var.subscription_id
}

output "location" {
  value = var.location
}

output "resource_group" {
  value = module.shared_azure_resources.all.resource_group_name
}

output "aws_region" {
  value = var.aws_region
}

output "aws_profile" {
  value = var.aws_profile
}

# --- Activity Logs pipeline (activity_logs) ---

output "al_s3_bucket" {
  value = module.activity_logs.s3_bucket_name
}

output "al_s3_prefix" {
  value = "azure/itest"
}

output "al_staging_account" {
  value = module.activity_logs.staging_storage_account_name
}

output "al_staging_container" {
  value = module.activity_logs.staging_container_name
}

output "al_eventhub_name" {
  value = module.activity_logs.eventhub_name
}

output "al_eventhub_send_connection" {
  value     = module.activity_logs.eventhub_send_connection_string
  sensitive = true
}

output "al_function_app" {
  value = module.activity_logs.function_app_name
}

output "al_diagnostic_setting" {
  value = module.activity_logs.diagnostic_setting_name
}

output "al_managed_identity_principal_id" {
  value = module.activity_logs.managed_identity_principal_id
}

output "al_aws_role_arn" {
  value = module.activity_logs.aws_role_arn
}

# --- Mirror pipeline (mir_new, filtered) ---

output "mirror_source_account" {
  value = azurerm_storage_account.mirror_source.name
}

output "mirror_source_container" {
  value = azurerm_storage_container.mirror_source.name
}

output "mirror_s3_bucket" {
  value = module.mir_new.s3_bucket_name
}

output "mirror_s3_key_prefix" {
  value = "blob/mirror"
}

output "mirror_function_app" {
  value = module.mir_new.function_app_name
}

output "mirror_system_topic" {
  value = module.mir_new.system_topic_name
}

output "mirror_event_subscriptions" {
  value = module.mir_new.event_subscription_names
}

output "mirror_dlq_account" {
  value = module.mir_new.dlq_storage_account_name
}

output "mirror_dlq_container" {
  value = module.mir_new.dlq_container_name
}

output "mirror_alert_name" {
  value = module.mir_new.alert_name
}

output "mirror_managed_identity_principal_id" {
  value = module.mir_new.managed_identity_principal_id
}

output "mirror_aws_role_arn" {
  value = module.mir_new.aws_role_arn
}

# --- Mirror pipeline (mir_ex, unfiltered, existing S3 bucket) ---

output "mirror_ex_source_account" {
  value = azurerm_storage_account.mirror_source_ex.name
}

output "mirror_ex_source_container" {
  value = azurerm_storage_container.mirror_source_ex.name
}

output "mirror_ex_s3_bucket" {
  value = module.mir_ex.s3_bucket_name
}

output "mirror_ex_s3_key_prefix" {
  value = "blob/existing"
}

output "mirror_ex_function_app" {
  value = module.mir_ex.function_app_name
}

output "mirror_ex_system_topic" {
  value = module.mir_ex.system_topic_name
}

output "mirror_ex_dlq_account" {
  value = module.mir_ex.dlq_storage_account_name
}

output "mirror_ex_dlq_container" {
  value = module.mir_ex.dlq_container_name
}

output "runner_ip_cidr" {
  # Echoed back so T2 can replay the plan with the exact vars run.sh applied
  # with, and T1e can assert the allow-list rule matches
  value = var.runner_ip_cidr
}
