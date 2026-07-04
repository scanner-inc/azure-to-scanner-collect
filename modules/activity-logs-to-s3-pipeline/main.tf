# Activity Logs to S3 pipeline
#
# Subscription diagnostic setting -> Event Hub -> batch function (gzip NDJSON
# staging blobs) -> Event Grid BlobCreated -> transfer function -> S3
# (+ timer sweep function retrying stale staging blobs)

terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
    }
    aws = {
      source = "hashicorp/aws"
    }
    random = {
      source = "hashicorp/random"
    }
  }
}

# Locals
locals {
  scanner_sns_provided  = var.scanner_sns_topic_arn != ""
  scanner_role_provided = var.scanner_role_arn != ""
  using_existing_bucket = var.existing_s3_bucket_name != ""

  resource_group_name = var.shared_azure_resources.resource_group_name
  location            = var.shared_azure_resources.location
  tenant_id           = var.shared_azure_resources.tenant_id

  # Condition-key prefix for the AWS trust policy: the OIDC provider URL
  # without the scheme (trailing slash included - it is part of the iss claim)
  oidc_condition_prefix = replace(var.shared_azure_resources.oidc_issuer_url, "https://", "")

  # Computed resource names - override if provided, else default from
  # var.name. Storage account names must be <= 24 lowercase alphanumerics,
  # hence the squeezed variants.
  name_squeezed = substr(replace(var.name, "-", ""), 0, 10)

  eventhub_namespace_name = var.eventhub_namespace_name != "" ? var.eventhub_namespace_name : "${var.name}-ehns-${random_id.suffix.hex}"
  eventhub_name           = var.eventhub_name != "" ? var.eventhub_name : "${var.name}-hub"
  diagnostic_setting_name = var.diagnostic_setting_name != "" ? var.diagnostic_setting_name : "${var.name}-to-eventhub-${random_id.suffix.hex}"
  staging_account_name    = var.staging_storage_account_name != "" ? var.staging_storage_account_name : "${local.name_squeezed}stg${random_id.suffix.hex}"
  staging_container_name  = var.staging_container_name != "" ? var.staging_container_name : "staging"
  function_storage_name   = var.function_storage_account_name != "" ? var.function_storage_account_name : "${local.name_squeezed}fn${random_id.suffix.hex}"
  function_app_name       = var.function_app_name != "" ? var.function_app_name : "${var.name}-fnapp-${random_id.suffix.hex}"
  managed_identity_name   = var.managed_identity_name != "" ? var.managed_identity_name : "${var.name}-mi-${random_id.suffix.hex}"
  system_topic_name       = var.system_topic_name != "" ? var.system_topic_name : "${var.name}-staging-topic-${random_id.suffix.hex}"
  event_subscription_name = "${var.name}-transfer-sub-${random_id.suffix.hex}"
  aws_role_name           = var.aws_role_name != "" ? var.aws_role_name : "azure-${var.name}-s3-writer-${random_id.suffix.hex}"
}

# Validate AWS account matches the configured account ID
data "aws_caller_identity" "current" {}

# Random suffix for unique naming; also carries the AWS account sanity check
# (a precondition halts the plan with a readable message)
resource "random_id" "suffix" {
  byte_length = 4

  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.current.account_id == var.aws_account_id
      error_message = <<-EOT
        AWS account ID mismatch: aws_account_id is set to ${var.aws_account_id} but the
        active AWS credentials belong to account ${data.aws_caller_identity.current.account_id}.
        Update aws_account_id in terraform.tfvars, or switch credentials via the
        aws_profile variable / AWS_PROFILE environment variable.
      EOT
    }
  }
}

# ============== Event Hub (Activity Log transport) ==============

resource "azurerm_eventhub_namespace" "this" {
  name                = local.eventhub_namespace_name
  location            = local.location
  resource_group_name = local.resource_group_name
  sku                 = "Standard"
  capacity            = 1

  public_network_access_enabled = true
}

resource "azurerm_eventhub" "this" {
  name              = local.eventhub_name
  namespace_id      = azurerm_eventhub_namespace.this.id
  partition_count   = var.eventhub_partition_count
  message_retention = 1
}

# Namespace-level send rule for the diagnostic setting
resource "azurerm_eventhub_namespace_authorization_rule" "diagnostic_sender" {
  name                = "diagnostic-sender"
  namespace_name      = azurerm_eventhub_namespace.this.name
  resource_group_name = local.resource_group_name

  send   = true
  listen = false
  manage = false
}

# Hub-level listen rule for the batch function's Event Hub trigger
resource "azurerm_eventhub_authorization_rule" "function_listener" {
  name                = "function-listener"
  namespace_name      = azurerm_eventhub_namespace.this.name
  eventhub_name       = azurerm_eventhub.this.name
  resource_group_name = local.resource_group_name

  listen = true
  send   = false
  manage = false
}

# Subscription-scoped diagnostic setting forwarding Activity Logs to the hub
resource "azurerm_monitor_diagnostic_setting" "activity_logs" {
  name               = local.diagnostic_setting_name
  target_resource_id = "/subscriptions/${var.subscription_id}"

  eventhub_authorization_rule_id = azurerm_eventhub_namespace_authorization_rule.diagnostic_sender.id
  eventhub_name                  = azurerm_eventhub.this.name

  dynamic "enabled_log" {
    for_each = toset(var.log_categories)
    content {
      category = enabled_log.value
    }
  }
}

# ============== Staging Storage (batched gzip NDJSON blobs) ==============

resource "azurerm_storage_account" "staging" {
  name                     = local.staging_account_name
  location                 = local.location
  resource_group_name      = local.resource_group_name
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  min_tls_version = "TLS1_2"
}

resource "azurerm_storage_container" "staging" {
  name                  = local.staging_container_name
  storage_account_id    = azurerm_storage_account.staging.id
  container_access_type = "private"
}

# ============== Managed Identity ==============
# One identity per pipeline: its principal id is pinned in the AWS trust
# policy, so each pipeline can only assume its own role.

resource "azurerm_user_assigned_identity" "this" {
  name                = local.managed_identity_name
  location            = local.location
  resource_group_name = local.resource_group_name
}

# Batch function writes staging blobs; transfer/sweep functions read + delete
# them
resource "azurerm_role_assignment" "staging_blob_contributor" {
  scope                = azurerm_storage_account.staging.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}

# ============== Function App (batch + transfer + sweep) ==============

resource "azurerm_storage_account" "function_backing" {
  name                     = local.function_storage_name
  location                 = local.location
  resource_group_name      = local.resource_group_name
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  min_tls_version = "TLS1_2"
}

resource "azurerm_application_insights" "this" {
  name                = "${var.name}-appinsights-${random_id.suffix.hex}"
  location            = local.location
  resource_group_name = local.resource_group_name
  workspace_id        = var.shared_azure_resources.log_analytics_workspace_id
  application_type    = "other"
}

resource "azurerm_service_plan" "this" {
  name                = "${var.name}-plan-${random_id.suffix.hex}"
  location            = local.location
  resource_group_name = local.resource_group_name
  os_type             = "Linux"
  sku_name            = var.functions_plan_sku
}

resource "azurerm_linux_function_app" "this" {
  name                = local.function_app_name
  location            = local.location
  resource_group_name = local.resource_group_name
  service_plan_id     = azurerm_service_plan.this.id

  storage_account_name       = azurerm_storage_account.function_backing.name
  storage_account_access_key = azurerm_storage_account.function_backing.primary_access_key

  https_only                  = true
  builtin_logging_enabled     = false
  functions_extension_version = "~4"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.this.id]
  }

  site_config {
    application_stack {
      python_version = "3.11"
    }
    application_insights_connection_string = azurerm_application_insights.this.connection_string

    # Inbound lockdown: only Event Grid's egress IPs may reach the runtime
    # host. Auth still rests on the per-function system key Event Grid
    # presents (?code=...) - the service tag is shared by all Azure customers'
    # Event Grid traffic, so it narrows exposure rather than replacing auth.
    # SCM (Kudu) keeps its own credentialed access so zip deploys work.
    ip_restriction_default_action = "Deny"

    ip_restriction {
      name        = "allow-eventgrid"
      service_tag = "AzureEventGrid"
      action      = "Allow"
      priority    = 100
    }

    dynamic "ip_restriction" {
      for_each = var.additional_allowed_cidrs
      content {
        name       = "allow-extra-${ip_restriction.key}"
        ip_address = ip_restriction.value
        action     = "Allow"
        priority   = 200 + ip_restriction.key
      }
    }
  }

  app_settings = {
    # Deployment: Kudu zip deploy with Oryx remote build (installs
    # requirements.txt server-side). PACKAGE_MD5 forces a redeploy whenever
    # the package content changes.
    SCM_DO_BUILD_DURING_DEPLOYMENT = "true"
    ENABLE_ORYX_BUILD              = "true"
    PACKAGE_MD5                    = var.shared_azure_resources.activity_logs_zip_md5

    # Event Hub trigger
    EVENTHUB_CONNECTION = azurerm_eventhub_authorization_rule.function_listener.primary_connection_string
    EVENTHUB_NAME       = azurerm_eventhub.this.name

    # Staging blob target
    STAGING_ACCOUNT   = azurerm_storage_account.staging.name
    STAGING_CONTAINER = azurerm_storage_container.staging.name
    LOG_PREFIX        = var.log_prefix

    # Sweep function
    SWEEP_SCHEDULE        = var.sweep_schedule
    AGE_THRESHOLD_MINUTES = tostring(var.age_threshold_minutes)

    # AWS delivery (OIDC federation - no static keys)
    AZURE_CLIENT_ID   = azurerm_user_assigned_identity.this.client_id
    AWS_OIDC_AUDIENCE = var.shared_azure_resources.aws_oidc_audience
    AWS_ROLE_ARN      = aws_iam_role.s3_writer_role.arn
    AWS_REGION        = var.aws_region
    TARGET_BUCKET     = local.target_bucket_name
  }

  zip_deploy_file = var.shared_azure_resources.activity_logs_zip_path
}

# ============== Event Grid: staging BlobCreated -> transfer function ==============
# No dead-letter destination: the transfer function swallows errors and the
# timer sweep function is the recovery path.

resource "azurerm_eventgrid_system_topic" "staging" {
  name                   = local.system_topic_name
  location               = local.location
  resource_group_name    = local.resource_group_name
  source_arm_resource_id = azurerm_storage_account.staging.id
  topic_type             = "Microsoft.Storage.StorageAccounts"
}

resource "azurerm_eventgrid_system_topic_event_subscription" "transfer" {
  name                = local.event_subscription_name
  system_topic        = azurerm_eventgrid_system_topic.staging.name
  resource_group_name = local.resource_group_name

  included_event_types = ["Microsoft.Storage.BlobCreated"]

  subject_filter {
    subject_begins_with = "/blobServices/default/containers/${azurerm_storage_container.staging.name}/blobs/"
  }

  azure_function_endpoint {
    function_id                       = "${azurerm_linux_function_app.this.id}/functions/transfer_staging_blob"
    max_events_per_batch              = 1
    preferred_batch_size_in_kilobytes = 64
  }

  retry_policy {
    max_delivery_attempts = 10
    event_time_to_live    = 1440
  }

  # The function must be deployed (zip deploy + trigger sync) before Event
  # Grid validates the endpoint
  depends_on = [azurerm_linux_function_app.this]
}

# ============== AWS Resources ==============

# Data source for existing S3 bucket (if specified)
data "aws_s3_bucket" "existing_bucket" {
  count  = local.using_existing_bucket ? 1 : 0
  bucket = var.existing_s3_bucket_name
}

# S3 Target Bucket (only create if not using existing)
resource "aws_s3_bucket" "target_bucket" {
  count         = local.using_existing_bucket ? 0 : 1
  bucket        = var.s3_bucket_name != "" ? var.s3_bucket_name : "${var.name}-s3-target-${var.aws_account_id}-${random_id.suffix.hex}"
  force_destroy = var.force_destroy_buckets
}

# S3 Bucket Versioning (only for created bucket)
resource "aws_s3_bucket_versioning" "target_bucket_versioning" {
  count  = local.using_existing_bucket ? 0 : 1
  bucket = aws_s3_bucket.target_bucket[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

# S3 Bucket Encryption (only for created bucket)
resource "aws_s3_bucket_server_side_encryption_configuration" "target_bucket_encryption" {
  count  = local.using_existing_bucket ? 0 : 1
  bucket = aws_s3_bucket.target_bucket[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# S3 Bucket Lifecycle (optional, only for created bucket)
# Off by default (infinite retention). Set s3_expiration_days > 0 to expire
# log objects once Scanner has indexed them (e.g., 7 days).
resource "aws_s3_bucket_lifecycle_configuration" "target_bucket_lifecycle" {
  count  = !local.using_existing_bucket && var.s3_expiration_days > 0 ? 1 : 0
  bucket = aws_s3_bucket.target_bucket[0].id

  rule {
    id     = "expire-log-objects"
    status = "Enabled"

    filter {}

    expiration {
      days = var.s3_expiration_days
    }

    # The bucket is versioned; clean up noncurrent versions shortly after expiry
    noncurrent_version_expiration {
      noncurrent_days = 1
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.target_bucket_versioning]
}

# S3 Bucket Notification Configuration (only for created bucket with scanner integration)
resource "aws_s3_bucket_notification" "scanner_notification" {
  count  = !local.using_existing_bucket && local.scanner_sns_provided ? 1 : 0
  bucket = aws_s3_bucket.target_bucket[0].id

  topic {
    topic_arn = var.scanner_sns_topic_arn
    events    = ["s3:ObjectCreated:*"]
  }
}

# Local variable to reference the bucket name (works for both created and existing)
locals {
  target_bucket_name = local.using_existing_bucket ? var.existing_s3_bucket_name : aws_s3_bucket.target_bucket[0].id
  target_bucket_arn  = local.using_existing_bucket ? data.aws_s3_bucket.existing_bucket[0].arn : aws_s3_bucket.target_bucket[0].arn
}

# IAM Role for the pipeline's managed identity to assume via OIDC
resource "aws_iam_role" "s3_writer_role" {
  name = local.aws_role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = var.shared_azure_resources.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            # sub of a managed-identity token is the identity's principal
            # (object) id; aud is the fixed audience the function requests
            "${local.oidc_condition_prefix}:sub" = azurerm_user_assigned_identity.this.principal_id
            "${local.oidc_condition_prefix}:aud" = var.shared_azure_resources.aws_oidc_audience
          }
        }
      }
    ]
  })
}

# IAM Policy for S3 access
resource "aws_iam_role_policy" "s3_writer_policy" {
  name = "${local.aws_role_name}-policy"
  role = aws_iam_role.s3_writer_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:HeadObject",
          "s3:ListBucket"
        ]
        Resource = [
          local.target_bucket_arn,
          "${local.target_bucket_arn}/*"
        ]
      }
    ]
  })
}

# IAM Policy for Scanner Role to read from S3 (only for created bucket)
resource "aws_iam_role_policy" "scanner_read_policy" {
  count = !local.using_existing_bucket && local.scanner_role_provided ? 1 : 0
  name  = "${var.name}-scanner-s3-read-policy-${random_id.suffix.hex}"
  role  = split("/", var.scanner_role_arn)[1]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetBucketNotification",
          "s3:GetEncryptionConfiguration",
          "s3:ListBucket",
          "s3:GetObject",
          "s3:GetObjectTagging"
        ]
        Resource = [
          local.target_bucket_arn,
          "${local.target_bucket_arn}/*"
        ]
      }
    ]
  })
}
