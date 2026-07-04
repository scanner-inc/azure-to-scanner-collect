# Blob Container to S3 mirror pipeline
#
# Customer storage account/container -> Event Grid BlobCreated (per-prefix
# subscriptions with retry + dead-letter) -> mirror function (key filters)
# -> S3. Source blobs are NEVER deleted.

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

  # Condition-key prefix for the AWS trust policy: the OIDC provider URL
  # without the scheme (trailing slash included - it is part of the iss claim)
  oidc_condition_prefix = replace(var.shared_azure_resources.oidc_issuer_url, "https://", "")

  # Computed resource names - override if provided, else default from var.name
  name_squeezed = substr(replace(var.name, "-", ""), 0, 10)

  function_storage_name = var.function_storage_account_name != "" ? var.function_storage_account_name : "${local.name_squeezed}mfn${random_id.suffix.hex}"
  function_app_name     = var.function_app_name != "" ? var.function_app_name : "${var.name}-mirror-${random_id.suffix.hex}"
  managed_identity_name = var.managed_identity_name != "" ? var.managed_identity_name : "${var.name}-mirror-mi-${random_id.suffix.hex}"
  system_topic_name     = var.system_topic_name != "" ? var.system_topic_name : "${var.name}-mirror-topic-${random_id.suffix.hex}"
  dlq_container_name    = var.dlq_container_name != "" ? var.dlq_container_name : "mirror-dead-letter"
  aws_role_name         = var.aws_role_name != "" ? var.aws_role_name : "azure-${var.name}-s3-writer-${random_id.suffix.hex}"

  # Key filters passed to the function as environment variables
  key_prefixes_csv = join(",", var.key_prefixes)

  # One Event Grid subscription per key prefix filters server-side: blobs
  # outside the prefixes never even invoke the function. No prefixes
  # configured = one unfiltered subscription.
  notification_prefixes = length(var.key_prefixes) > 0 ? toset(var.key_prefixes) : toset([""])

  # A storage account has exactly ONE Event Grid system topic. Create it when
  # this module is the first Event Grid consumer of the account; otherwise
  # attach subscriptions to the existing topic (subscriptions are additive,
  # up to 500 per topic).
  system_topic_name_effective = var.create_system_topic ? azurerm_eventgrid_system_topic.source[0].name : var.existing_system_topic_name
}

data "azurerm_client_config" "current" {}

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

# ============== Source Storage Account (customer-owned) ==============

# The existing storage account to monitor (blobs are copied to S3, never
# deleted)
data "azurerm_storage_account" "source" {
  name                = var.source_storage_account_name
  resource_group_name = var.source_storage_account_resource_group
}

# ============== Managed Identity ==============

resource "azurerm_user_assigned_identity" "this" {
  name                = local.managed_identity_name
  location            = local.location
  resource_group_name = local.resource_group_name
}

# Grant the mirror function READ-ONLY access to the monitored account
# (mirror pipelines copy blobs to S3, they never delete from the source)
resource "azurerm_role_assignment" "source_blob_reader" {
  scope                = data.azurerm_storage_account.source.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}

# ============== Mirror Function App ==============

resource "azurerm_storage_account" "function_backing" {
  name                     = local.function_storage_name
  location                 = local.location
  resource_group_name      = local.resource_group_name
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  min_tls_version = "TLS1_2"
}

# Dead-lettered events land here (blobs that repeatedly failed to copy)
resource "azurerm_storage_container" "dlq" {
  name                  = local.dlq_container_name
  storage_account_id    = azurerm_storage_account.function_backing.id
  container_access_type = "private"
}

resource "azurerm_application_insights" "this" {
  name                = "${var.name}-mirror-appinsights-${random_id.suffix.hex}"
  location            = local.location
  resource_group_name = local.resource_group_name
  workspace_id        = var.shared_azure_resources.log_analytics_workspace_id
  application_type    = "other"
}

resource "azurerm_service_plan" "this" {
  name                = "${var.name}-mirror-plan-${random_id.suffix.hex}"
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
    PACKAGE_MD5                    = var.shared_azure_resources.mirror_zip_md5

    # Source container
    SOURCE_ACCOUNT   = data.azurerm_storage_account.source.name
    SOURCE_CONTAINER = var.source_container_name

    # Key path filtering (prefixes also filter server-side via Event Grid
    # subject_begins_with; regexes only apply in the function)
    KEY_PREFIXES      = local.key_prefixes_csv
    KEY_INCLUDE_REGEX = var.key_include_regex
    KEY_EXCLUDE_REGEX = var.key_exclude_regex
    S3_KEY_PREFIX     = var.s3_key_prefix

    # AWS delivery (OIDC federation - no static keys)
    AZURE_CLIENT_ID   = azurerm_user_assigned_identity.this.client_id
    AWS_OIDC_AUDIENCE = var.shared_azure_resources.aws_oidc_audience
    AWS_ROLE_ARN      = aws_iam_role.s3_writer_role.arn
    AWS_REGION        = var.aws_region
    TARGET_BUCKET     = local.target_bucket_name
  }

  zip_deploy_file = var.shared_azure_resources.mirror_zip_path
}

# ============== Event Grid: source BlobCreated -> mirror function ==============

resource "azurerm_eventgrid_system_topic" "source" {
  count = var.create_system_topic ? 1 : 0

  name                   = local.system_topic_name
  location               = data.azurerm_storage_account.source.location
  resource_group_name    = var.source_storage_account_resource_group
  source_arm_resource_id = data.azurerm_storage_account.source.id
  topic_type             = "Microsoft.Storage.StorageAccounts"
}

# One subscription per key prefix (server-side filtering). Failed deliveries
# retry with backoff; events that exhaust max_delivery_attempts (or expire)
# dead-letter to the DLQ container, where the monitoring alert fires.
resource "azurerm_eventgrid_system_topic_event_subscription" "mirror" {
  for_each = local.notification_prefixes

  name                = "${var.name}-mirror-sub-${substr(md5(each.value), 0, 6)}-${random_id.suffix.hex}"
  system_topic        = local.system_topic_name_effective
  resource_group_name = var.source_storage_account_resource_group

  included_event_types = ["Microsoft.Storage.BlobCreated"]

  subject_filter {
    subject_begins_with = "/blobServices/default/containers/${var.source_container_name}/blobs/${each.value}"
  }

  azure_function_endpoint {
    function_id                       = "${azurerm_linux_function_app.this.id}/functions/mirror_blob"
    max_events_per_batch              = 1
    preferred_batch_size_in_kilobytes = 64
  }

  retry_policy {
    max_delivery_attempts = var.max_delivery_attempts
    event_time_to_live    = var.event_ttl_minutes
  }

  storage_blob_dead_letter_destination {
    storage_account_id          = azurerm_storage_account.function_backing.id
    storage_blob_container_name = azurerm_storage_container.dlq.name
  }

  # The function must be deployed (zip deploy + trigger sync) before Event
  # Grid validates the endpoint
  depends_on = [azurerm_linux_function_app.this]
}

# ============== Dead-letter monitoring ==============

# Optional email channel for the dead-letter alert
resource "azurerm_monitor_action_group" "email" {
  count = var.alert_email != "" ? 1 : 0

  name                = "${var.name}-mirror-alerts-${random_id.suffix.hex}"
  resource_group_name = local.resource_group_name
  short_name          = substr("${var.name}dlq", 0, 12)

  email_receiver {
    name          = "ops"
    email_address = var.alert_email
  }
}

# Fires when any event is dead-lettered: delivery to the mirror function
# failed repeatedly and manual attention is needed (inspect the DLQ
# container, fix the cause, replay)
resource "azurerm_monitor_metric_alert" "dead_letter_alert" {
  count = var.create_system_topic ? 1 : 0

  name                = "${var.name}-mirror-dead-letter-alert-${random_id.suffix.hex}"
  resource_group_name = local.resource_group_name
  scopes              = [azurerm_eventgrid_system_topic.source[0].id]
  description         = <<-EOT
    Events from the ${var.name} blob->S3 mirror pipeline exhausted their
    delivery attempts and were dead-lettered to the
    ${local.dlq_container_name} container in storage account
    ${azurerm_storage_account.function_backing.name}. Each dead-lettered
    event names one blob that was NOT copied to S3. The function is
    idempotent - blobs already in S3 are skipped - so events can be replayed
    by re-uploading the source blobs or invoking the function manually.
  EOT
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "Microsoft.EventGrid/systemTopics"
    metric_name      = "DeadLetteredCount"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 0
  }

  dynamic "action" {
    for_each = var.alert_email != "" ? [1] : []
    content {
      action_group_id = azurerm_monitor_action_group.email[0].id
    }
  }
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

# S3 Bucket Lifecycle (only for created bucket)
# On by default (7 days): the S3 copy is a short-lived buffer for Scanner to
# index, not a permanent duplicate of data still in Azure. Set
# s3_expiration_days = 0 for infinite retention.
resource "aws_s3_bucket_lifecycle_configuration" "target_bucket_lifecycle" {
  count  = !local.using_existing_bucket && var.s3_expiration_days > 0 ? 1 : 0
  bucket = aws_s3_bucket.target_bucket[0].id

  rule {
    id     = "expire-mirrored-objects"
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
