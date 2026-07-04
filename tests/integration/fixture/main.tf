# Integration test fixture
#
# Deploys the modules under test into dedicated test accounts:
#   - activity_logs: activity-logs-to-s3-pipeline with an auto-created S3 bucket
#   - mir_new:       blob-container-to-s3-pipeline with all key filters set
#   - mir_ex:        blob-container-to-s3-pipeline, unfiltered, into a
#                    fixture-created "existing" S3 bucket, with low dead-letter
#                    knobs for the bounded dead-letter test
#
# Every resource name embeds var.run_suffix so runs can't collide and orphans
# are attributable to a run. All Azure resources live in one run-suffixed
# resource group, so cleanup collapses to "is the resource group gone".
# Nothing references pre-existing resources; destroy removes only what the
# fixture created.
#
# NOTE: one run at a time per (AWS account, Entra tenant) pair - the shared
# module creates the AWS OIDC provider, whose issuer URL is unique per account.

terraform {
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

provider "azurerm" {
  features {
    resource_group {
      # The RG briefly contains function-app leftovers during destroy
      prevent_deletion_if_contains_resources = false
    }
  }
  subscription_id = var.subscription_id

  # run.sh preflight verifies the needed providers are registered; azurerm's
  # default auto-registration of its core set can silently stall the first
  # apply for many minutes
  resource_provider_registrations = "none"
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

locals {
  # Pipeline module names must match ^[a-z][a-z0-9-]{0,17}$
  activity_name = "it-${var.run_suffix}-al"
  mir_new_name  = "it-${var.run_suffix}-mn"
  mir_ex_name   = "it-${var.run_suffix}-me"

  resource_group_name = "it-${var.run_suffix}-rg"

  # The function apps default-deny inbound except Event Grid; the runner is
  # allow-listed so tests can reach the admin API (L5) and probe auth (AUTH1)
  additional_allowed_cidrs = var.runner_ip_cidr == "" ? [] : [var.runner_ip_cidr]
}

# ============== Shared Azure resources ==============
# Creates the run's resource group, the AWS OIDC provider, the Log Analytics
# workspace, and the function deployment packages.

module "shared_azure_resources" {
  source = "../../../modules/shared-azure-resources"

  resource_group_name = local.resource_group_name
  location            = var.location
}

# Data-plane access for the test driver (signed-in az principal): one
# role assignment at resource-group scope covers every storage account the
# fixture and modules create. RBAC propagation is slow (minutes); the settle
# canaries absorb it.
resource "azurerm_role_assignment" "test_principal_blob_contributor" {
  count = var.test_principal_object_id != "" ? 1 : 0

  scope                = "/subscriptions/${var.subscription_id}/resourceGroups/${module.shared_azure_resources.all.resource_group_name}"
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = var.test_principal_object_id
}

# ============== Activity Logs pipeline under test ==============

module "activity_logs" {
  source = "../../../modules/activity-logs-to-s3-pipeline"

  name                   = local.activity_name
  shared_azure_resources = module.shared_azure_resources.all

  subscription_id = var.subscription_id
  aws_account_id  = var.aws_account_id
  aws_region      = var.aws_region

  log_prefix = "azure/itest"

  # Exercises the lifecycle opt-in path (asserted by the contract tests)
  s3_expiration_days = 7

  # Age 0 so the on-demand sweep-retry test doesn't wait 30 minutes for a
  # stranded staging blob to count as stale
  age_threshold_minutes = 0

  additional_allowed_cidrs = local.additional_allowed_cidrs

  force_destroy_buckets = true
}

# ============== Blob mirror pipeline under test (filtered) ==============

# Stand-in for a customer-owned storage account of raw logs. Created by the
# fixture, monitored (never deleted from) by the module under test.
resource "azurerm_storage_account" "mirror_source" {
  name                     = "it${var.run_suffix}src"
  location                 = var.location
  resource_group_name      = module.shared_azure_resources.all.resource_group_name
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  lifecycle {
    # azurerm reads back `tags = {}` and plans a perpetual `{} -> null` no-op.
    # A pending change here defers the mirror module's data-source reads (via
    # depends_on), cascading known-after-apply drift into T2.
    ignore_changes = [tags]
  }
}

resource "azurerm_storage_container" "mirror_source" {
  name                  = "raw-logs"
  storage_account_id    = azurerm_storage_account.mirror_source.id
  container_access_type = "private"
}

module "mir_new" {
  source = "../../../modules/blob-container-to-s3-pipeline"

  # The module reads the source account via a data source; since it's created
  # in this same config, defer that read to apply
  depends_on = [azurerm_storage_account.mirror_source, azurerm_storage_container.mirror_source]

  name                   = local.mir_new_name
  shared_azure_resources = module.shared_azure_resources.all

  aws_account_id = var.aws_account_id
  aws_region     = var.aws_region

  source_storage_account_name           = azurerm_storage_account.mirror_source.name
  source_storage_account_resource_group = module.shared_azure_resources.all.resource_group_name
  source_container_name                 = azurerm_storage_container.mirror_source.name

  # All three filter mechanisms in play, so tests can cover each
  key_prefixes      = ["logs/"]
  key_include_regex = "\\.(json|jsonl)(\\.gz)?$"
  key_exclude_regex = "\\.tmp$"

  s3_key_prefix      = "blob/mirror"
  s3_expiration_days = 7

  additional_allowed_cidrs = local.additional_allowed_cidrs

  # No alert_email: the dead-letter alert rule is still created (asserted by
  # the contract tests), just without an email action

  force_destroy_buckets = true
}

# ============== Blob mirror pipeline under test (existing bucket) ==============
# Exercises paths the primary mirror instance doesn't:
#   - existing_s3_bucket_name (fixture-created, handed to the module as
#     "existing"; module must not manage lifecycle/notifications on it)
#   - no key filters (everything mirrors)
#   - a second system topic on a second storage account (multi-instance
#     coexistence)
#   - low dead-letter knobs so the dead-letter test completes in bounded time

resource "azurerm_storage_account" "mirror_source_ex" {
  name                     = "it${var.run_suffix}se"
  location                 = var.location
  resource_group_name      = module.shared_azure_resources.all.resource_group_name
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  lifecycle {
    # See mirror_source: silence the azurerm tags {}->null no-op so module
    # data-source reads aren't deferred on re-plans
    ignore_changes = [tags]
  }
}

resource "azurerm_storage_container" "mirror_source_ex" {
  name                  = "raw-logs"
  storage_account_id    = azurerm_storage_account.mirror_source_ex.id
  container_access_type = "private"
}

# Stand-in for a customer's pre-existing S3 bucket
resource "aws_s3_bucket" "mirror_existing_target" {
  bucket        = "it-${var.run_suffix}-mirror-existing-${var.aws_account_id}"
  force_destroy = true
}

module "mir_ex" {
  source = "../../../modules/blob-container-to-s3-pipeline"

  depends_on = [
    azurerm_storage_account.mirror_source_ex,
    azurerm_storage_container.mirror_source_ex,
    aws_s3_bucket.mirror_existing_target,
  ]

  name                   = local.mir_ex_name
  shared_azure_resources = module.shared_azure_resources.all

  aws_account_id = var.aws_account_id
  aws_region     = var.aws_region

  source_storage_account_name           = azurerm_storage_account.mirror_source_ex.name
  source_storage_account_resource_group = module.shared_azure_resources.all.resource_group_name
  source_container_name                 = azurerm_storage_container.mirror_source_ex.name

  # No filters: everything mirrors
  s3_key_prefix           = "blob/existing"
  existing_s3_bucket_name = aws_s3_bucket.mirror_existing_target.bucket

  # Low dead-letter knobs: a delivery outage dead-letters within ~5 minutes
  # instead of Event Grid's default 24h, so the dead-letter test is bounded.
  # 3 attempts still tolerate a function cold start on the happy path.
  max_delivery_attempts = 3
  event_ttl_minutes     = 5

  additional_allowed_cidrs = local.additional_allowed_cidrs

  force_destroy_buckets = true
}
