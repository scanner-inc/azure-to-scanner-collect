# Single structured output containing all shared resources
# Pass this entire object to pipeline modules via:
#   shared_azure_resources = module.shared_azure_resources.all

output "all" {
  description = "All shared Azure resources in a structured object"
  value = {
    # Resource group all pipeline resources live in
    resource_group_name = azurerm_resource_group.this.name
    location            = azurerm_resource_group.this.location

    # Entra tenant + AWS OIDC federation
    tenant_id         = local.tenant_id
    oidc_issuer_url   = local.oidc_issuer_url
    oidc_provider_arn = local.oidc_provider_arn
    aws_oidc_audience = local.aws_oidc_audience

    # Application Insights backing workspace
    log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

    # Function deployment packages
    activity_logs_zip_path = data.archive_file.activity_logs_package.output_path
    activity_logs_zip_md5  = data.archive_file.activity_logs_package.output_md5
    mirror_zip_path        = data.archive_file.mirror_package.output_path
    mirror_zip_md5         = data.archive_file.mirror_package.output_md5
  }
}

# Individual outputs for convenience (optional, can use .all instead)
output "resource_group_name" {
  description = "Name of the resource group for all pipeline resources"
  value       = azurerm_resource_group.this.name
}

output "oidc_provider_arn" {
  description = "ARN of the AWS IAM OIDC identity provider for the Entra tenant"
  value       = local.oidc_provider_arn
}

output "tenant_id" {
  description = "Entra ID tenant ID"
  value       = local.tenant_id
}
