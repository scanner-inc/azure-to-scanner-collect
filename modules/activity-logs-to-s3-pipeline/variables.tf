# Pipeline Identification
variable "name" {
  description = "Name for this pipeline (used to prefix all resource names for easy identification, e.g., 'activity-logs')"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,17}$", var.name))
    error_message = "Name must start with a letter, contain only lowercase letters, numbers, and hyphens, and be 1-18 characters long (required for storage account names to fit within 24 char limit)."
  }
}

# Shared Azure Resources
variable "shared_azure_resources" {
  description = "Shared Azure resources from the shared-azure-resources module (pass module.shared_azure_resources.all)"
  type = object({
    resource_group_name        = string
    location                   = string
    tenant_id                  = string
    oidc_issuer_url            = string
    oidc_provider_arn          = string
    aws_oidc_audience          = string
    log_analytics_workspace_id = string
    activity_logs_zip_path     = string
    activity_logs_zip_md5      = string
    mirror_zip_path            = string
    mirror_zip_md5             = string
  })
}

# Azure Configuration
variable "subscription_id" {
  description = "Azure Subscription ID whose Activity Logs are exported"
  type        = string
}

# AWS Configuration
variable "aws_region" {
  description = "AWS Region"
  type        = string
  default     = "us-east-1"
}

variable "aws_account_id" {
  description = "AWS Account ID"
  type        = string
}

# Activity Log Configuration
variable "log_categories" {
  description = "Activity Log categories forwarded to the Event Hub"
  type        = list(string)
  default = [
    "Administrative",
    "Security",
    "ServiceHealth",
    "Alert",
    "Recommendation",
    "Policy",
    "Autoscale",
    "ResourceHealth",
  ]
}

variable "log_prefix" {
  description = "Key prefix for log objects written to staging and S3 (e.g., 'azure/activity')"
  type        = string
  default     = "azure/activity"
}

variable "eventhub_partition_count" {
  description = "Number of Event Hub partitions (throughput knob; Activity Logs rarely need more than the default)"
  type        = number
  default     = 4

  validation {
    condition     = var.eventhub_partition_count >= 1 && var.eventhub_partition_count <= 32
    error_message = "eventhub_partition_count must be between 1 and 32 (Standard tier limits)."
  }
}

# Sweep (recovery) Function Configuration
variable "sweep_schedule" {
  description = "NCRONTAB schedule for the sweep function that retries stale staging blobs"
  type        = string
  default     = "0 */30 * * * *" # every 30 minutes
}

variable "age_threshold_minutes" {
  description = "Age threshold in minutes for the sweep function to consider staging blobs stale"
  type        = number
  default     = 30
}

# Function Hosting
variable "functions_plan_sku" {
  description = "App Service plan SKU for the function app (Y1 = Linux Consumption; use EP1 for Elastic Premium if cold starts matter)"
  type        = string
  default     = "Y1"
}

variable "additional_allowed_cidrs" {
  description = "Extra CIDRs allowed to reach the function app's runtime host (e.g., a test runner needing the admin API). Event Grid is always allowed via service tag; the default is Event-Grid-only."
  type        = list(string)
  default     = []
}

# S3 Destination Configuration
variable "s3_bucket_name" {
  description = "Name for the S3 bucket to create (if not using existing_s3_bucket_name). If empty, generates: {name}-s3-target-{account_id}-{random_suffix}"
  type        = string
  default     = ""

  validation {
    condition     = var.s3_bucket_name == "" || can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.s3_bucket_name))
    error_message = "s3_bucket_name must be a valid S3 bucket name (3-63 chars, lowercase letters, numbers, dots, hyphens)."
  }

  validation {
    condition     = var.s3_bucket_name == "" || var.existing_s3_bucket_name == ""
    error_message = "Cannot specify both s3_bucket_name and existing_s3_bucket_name. Use one or the other."
  }
}

variable "existing_s3_bucket_name" {
  description = "Use an existing S3 bucket instead of creating a new one (cannot use scanner variables; lifecycle policy is not managed)"
  type        = string
  default     = ""

  validation {
    condition     = var.existing_s3_bucket_name == "" || (var.scanner_sns_topic_arn == "" && var.scanner_role_arn == "")
    error_message = "When using an existing S3 bucket, you cannot specify scanner_sns_topic_arn or scanner_role_arn (configure scanner integration directly in your AWS account)."
  }
}

variable "s3_expiration_days" {
  description = "Optional: days after which log objects are deleted from the created S3 bucket (e.g., 7; Scanner has indexed them by then). Default 0 = retain indefinitely. Only applies when this module creates the bucket."
  type        = number
  default     = 0

  validation {
    condition     = var.s3_expiration_days >= 0
    error_message = "s3_expiration_days must be 0 (infinite retention) or a positive number of days."
  }
}

variable "force_destroy_buckets" {
  description = "Allow deletion of non-empty buckets (useful for testing/development)"
  type        = bool
  default     = false
}

# Scanner Integration
variable "scanner_sns_topic_arn" {
  description = "Optional SNS topic ARN for S3 object created notifications (requires scanner_role_arn)"
  type        = string
  default     = ""

  validation {
    condition     = var.scanner_sns_topic_arn == "" || can(regex("^arn:aws:sns:[a-z0-9-]+:[0-9]{12}:.+$", var.scanner_sns_topic_arn))
    error_message = "scanner_sns_topic_arn must be a valid SNS topic ARN or empty string."
  }
}

variable "scanner_role_arn" {
  description = "Optional scanner role ARN to grant S3 read permissions (requires scanner_sns_topic_arn)"
  type        = string
  default     = ""

  validation {
    condition     = var.scanner_role_arn == "" || can(regex("^arn:aws:iam::[0-9]{12}:role/.+$", var.scanner_role_arn))
    error_message = "scanner_role_arn must be a valid IAM role ARN or empty string."
  }

  validation {
    condition     = (var.scanner_sns_topic_arn == "") == (var.scanner_role_arn == "")
    error_message = "Both scanner_sns_topic_arn and scanner_role_arn must be specified together, or neither should be specified."
  }
}

# Optional Resource Name Overrides
# If not specified, sensible defaults based on 'name' will be used

variable "eventhub_namespace_name" {
  description = "Override name for the Event Hub namespace (default: {name}-ehns-{suffix}; globally unique)"
  type        = string
  default     = ""
}

variable "eventhub_name" {
  description = "Override name for the Event Hub (default: {name}-hub)"
  type        = string
  default     = ""
}

variable "diagnostic_setting_name" {
  description = "Override name for the subscription diagnostic setting (default: {name}-to-eventhub-{suffix})"
  type        = string
  default     = ""
}

variable "staging_storage_account_name" {
  description = "Override name for the staging storage account (default: {squeezed-name}stg{suffix}; globally unique, <=24 lowercase alphanumerics)"
  type        = string
  default     = ""
}

variable "staging_container_name" {
  description = "Override name for the staging blob container (default: staging)"
  type        = string
  default     = ""
}

variable "function_storage_account_name" {
  description = "Override name for the function app's backing storage account (default: {squeezed-name}fn{suffix})"
  type        = string
  default     = ""
}

variable "function_app_name" {
  description = "Override name for the function app (default: {name}-fnapp-{suffix}; globally unique)"
  type        = string
  default     = ""
}

variable "managed_identity_name" {
  description = "Override name for the user-assigned managed identity (default: {name}-mi-{suffix})"
  type        = string
  default     = ""
}

variable "system_topic_name" {
  description = "Override name for the Event Grid system topic on the staging account (default: {name}-staging-topic-{suffix})"
  type        = string
  default     = ""
}

variable "aws_role_name" {
  description = "Override name for AWS IAM role (default: azure-{name}-s3-writer-{suffix})"
  type        = string
  default     = ""
}
