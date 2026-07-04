# Configure providers
terraform {
  # >= 1.9 required for cross-variable references in variable validation blocks
  required_version = ">= 1.9"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

# Configure providers
provider "azurerm" {
  features {}
  subscription_id = var.subscription_id

  # This project needs these resource providers registered (once per
  # subscription; most subscriptions already have them):
  #   az provider register -n Microsoft.EventGrid --wait
  #   az provider register -n Microsoft.EventHub --wait
  #   az provider register -n Microsoft.Web --wait
  #   az provider register -n Microsoft.Storage --wait
  #   az provider register -n Microsoft.ManagedIdentity --wait
  #   az provider register -n Microsoft.OperationalInsights --wait
  #   az provider register -n microsoft.insights --wait
  # azurerm's default auto-registration of its full core set can silently
  # stall the first apply for many minutes, so it is disabled.
  resource_provider_registrations = "none"
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

# ============================================================================
# Shared Azure Resources
# ============================================================================
# This module contains resources that only need to exist once per deployment:
# - Resource group for all pipeline resources
# - AWS IAM OIDC identity provider trusting the Entra ID tenant
# - Storage account holding the packaged function code
#
# All pipeline modules depend on this shared module.

module "shared_azure_resources" {
  source = "./modules/shared-azure-resources"

  resource_group_name = var.resource_group_name
  location            = var.location

  # Optional: Override the function package storage account name
  # package_storage_account_name = "mycustompkgstore"
}

# ============================================================================
# Pipeline Modules
# ============================================================================
# Each pipeline instance requires the shared_azure_resources module above.
# Keep the shared module, then uncomment one or more pipelines below.
#
# Most common configurations are listed first: Azure Activity Logs
# (new or existing S3 bucket).

# Azure Activity Logs to a new S3 bucket (Scanner integration enabled)
# module "activity_logs_pipeline" {
#   source = "./modules/activity-logs-to-s3-pipeline"
#
#   name                   = "activity-logs"
#   shared_azure_resources = module.shared_azure_resources.all
#
#   subscription_id = var.subscription_id
#   aws_account_id  = var.aws_account_id
#   aws_region      = var.aws_region
#
#   log_prefix = "azure/activity"
#   # s3_bucket_name = "mycompany-azure-activity-logs"
#
#   # Optional: restrict which Activity Log categories are forwarded
#   # log_categories = ["Administrative", "Security", "Policy"]
#
#   # Optional: expire log objects from the created bucket after N days
#   # (e.g., 7, once Scanner has indexed them). Default: retain indefinitely.
#   # s3_expiration_days = 7
#
#   # Optional: the function app default-denies inbound except Event Grid;
#   # allow-list extra CIDRs if something else must reach it (e.g., a CI
#   # runner using the Functions admin API)
#   # additional_allowed_cidrs = ["203.0.113.7/32"]
#
#   force_destroy_buckets = var.force_destroy_buckets
#
#   # Scanner integration:
#   scanner_sns_topic_arn = var.scanner_sns_topic_arn
#   scanner_role_arn      = var.scanner_role_arn
# }

# Azure Activity Logs to an existing S3 bucket
# module "activity_logs_to_existing_bucket" {
#   source = "./modules/activity-logs-to-s3-pipeline"
#
#   name                   = "activity-logs"
#   shared_azure_resources = module.shared_azure_resources.all
#
#   subscription_id = var.subscription_id
#   aws_account_id  = var.aws_account_id
#   aws_region      = var.aws_region
#
#   log_prefix              = "azure/activity"
#   existing_s3_bucket_name = "my-existing-scanner-bucket"
#
#   # Cannot use scanner variables with existing bucket
#   # (assume bucket is already configured)
# }

# ============================================================================
# Blob Container Mirror Pipelines
# ============================================================================
# Mirror raw logs from existing Azure Blob Storage containers to S3 so Scanner
# can index them. On each blob creation, the blob name is checked against
# configurable filters (prefixes / include regex / exclude regex); matching
# blobs are copied to S3. Blobs are NEVER deleted from the source container.
# One module instance per monitored container, each with its own S3 bucket.

# Mirror an existing blob container of raw logs to a new S3 bucket
# (Scanner integration enabled)
# module "raw_logs_mirror" {
#   source = "./modules/blob-container-to-s3-pipeline"
#
#   name                   = "raw-logs"
#   shared_azure_resources = module.shared_azure_resources.all
#
#   aws_account_id = var.aws_account_id
#   aws_region     = var.aws_region
#
#   # The existing storage account + container to monitor
#   source_storage_account_name           = "mycompanyrawlogs"
#   source_storage_account_resource_group = "my-logs-rg"
#   source_container_name                 = "raw-logs"
#
#   # Customizable key path filtering (all configured filters must pass):
#   key_prefixes      = ["logs/"]      # only blobs under these prefixes
#   # key_include_regex = "\\.json(\\.gz)?$"  # only blobs matching this regex
#   key_exclude_regex = "\\.tmp$"      # skip blobs matching this regex
#
#   # Namespace mirrored objects within the S3 bucket
#   s3_key_prefix = "azure/raw-logs"
#
#   # s3_bucket_name = "mycompany-blob-raw-logs-mirror"  # optional custom name
#
#   # Mirrored objects in the created S3 bucket expire after 7 days by default
#   # (S3 is a buffer, not a permanent copy). Override the retention window,
#   # or set 0 to keep objects indefinitely.
#   # s3_expiration_days = 7
#
#   # Optional: email alerts when blobs repeatedly fail to copy and land in
#   # the dead-letter container (the alert rule exists either way)
#   # alert_email = "ops@mycompany.com"
#
#   # Optional: the function app default-denies inbound except Event Grid;
#   # allow-list extra CIDRs if something else must reach it
#   # additional_allowed_cidrs = ["203.0.113.7/32"]
#
#   force_destroy_buckets = var.force_destroy_buckets
#
#   # Scanner integration:
#   scanner_sns_topic_arn = var.scanner_sns_topic_arn
#   scanner_role_arn      = var.scanner_role_arn
# }

# Mirror an existing blob container to an existing S3 bucket
# module "raw_logs_mirror_to_existing_bucket" {
#   source = "./modules/blob-container-to-s3-pipeline"
#
#   name                   = "raw-logs"
#   shared_azure_resources = module.shared_azure_resources.all
#
#   aws_account_id = var.aws_account_id
#   aws_region     = var.aws_region
#
#   source_storage_account_name           = "mycompanyrawlogs"
#   source_storage_account_resource_group = "my-logs-rg"
#   source_container_name                 = "raw-logs"
#   key_prefixes                          = ["logs/"]
#   s3_key_prefix                         = "azure/raw-logs"
#
#   existing_s3_bucket_name = "my-existing-scanner-bucket"
#
#   # Cannot use scanner variables with existing bucket
#   # (assume bucket is already configured; lifecycle policy is not managed)
# }
