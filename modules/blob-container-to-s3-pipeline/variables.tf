# Pipeline Identification
variable "name" {
  description = "Name for this mirror pipeline (used to prefix all resource names for easy identification, e.g., 'raw-logs', 'lb-logs')"
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

# Source Storage Configuration
variable "source_storage_account_name" {
  description = "Name of the existing storage account to monitor (blobs are copied to S3, never deleted)"
  type        = string
}

variable "source_storage_account_resource_group" {
  description = "Resource group of the source storage account"
  type        = string
}

variable "source_container_name" {
  description = "Name of the blob container to monitor for new blobs"
  type        = string
}

variable "create_system_topic" {
  description = "Create the Event Grid system topic on the source storage account. A storage account has exactly ONE system topic; set this to false and provide existing_system_topic_name if one already exists (event subscriptions are additive, up to 500 per topic)."
  type        = bool
  default     = true

  validation {
    condition     = var.create_system_topic || var.existing_system_topic_name != ""
    error_message = "existing_system_topic_name is required when create_system_topic is false."
  }
}

variable "existing_system_topic_name" {
  description = "Name of the existing Event Grid system topic on the source storage account (required when create_system_topic = false; must be in the source account's resource group)"
  type        = string
  default     = ""
}

variable "max_function_instances" {
  description = "Maximum concurrent instances of the mirror function (the throughput knob; at millions of blobs/day keep this high)"
  type        = number
  default     = 100

  validation {
    condition     = var.max_function_instances >= 1
    error_message = "max_function_instances must be at least 1."
  }
}

variable "max_delivery_attempts" {
  description = "Event Grid delivery attempts (with exponential backoff) before an event is dead-lettered"
  type        = number
  default     = 30

  validation {
    condition     = var.max_delivery_attempts >= 1 && var.max_delivery_attempts <= 30
    error_message = "max_delivery_attempts must be between 1 and 30 (Event Grid limits)."
  }
}

variable "event_ttl_minutes" {
  description = "Event Grid event time-to-live in minutes; events not delivered within this window are dead-lettered"
  type        = number
  default     = 1440

  validation {
    condition     = var.event_ttl_minutes >= 1 && var.event_ttl_minutes <= 1440
    error_message = "event_ttl_minutes must be between 1 and 1440 (Event Grid limits)."
  }
}

variable "alert_email" {
  description = "Optional email address notified when events are dead-lettered (blobs that repeatedly failed to copy to S3). Empty = alert rule still created, no email action."
  type        = string
  default     = ""

  validation {
    condition     = var.alert_email == "" || can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email must be a valid email address or empty string."
  }
}

# Key Path Filtering
# All configured filters must pass for a blob to be copied to S3.
# Unset filters are skipped (default: everything passes).
variable "key_prefixes" {
  description = "Only copy blobs whose name starts with one of these prefixes (e.g., ['logs/', 'exports/']). Applied server-side: one Event Grid subscription per prefix, so non-matching blobs never invoke the function. Empty list = all blobs pass."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for p in var.key_prefixes : !can(regex(",", p))])
    error_message = "key_prefixes entries cannot contain commas (they are passed to the function as a comma-separated list)."
  }

  validation {
    condition     = length(distinct(var.key_prefixes)) <= 10
    error_message = "At most 10 key_prefixes are supported: each prefix becomes an Event Grid subscription. Use broader prefixes plus key_include_regex/key_exclude_regex for finer filtering."
  }
}

variable "key_include_regex" {
  description = "Only copy blobs whose name matches this regex (Python re.search syntax, e.g., '\\.json(\\.gz)?$'). Empty = all blobs pass."
  type        = string
  default     = ""
}

variable "key_exclude_regex" {
  description = "Skip blobs whose name matches this regex (Python re.search syntax, e.g., '\\.tmp$'). Empty = nothing excluded."
  type        = string
  default     = ""
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
variable "s3_key_prefix" {
  description = "Prefix prepended to blob names when writing to S3 (e.g., 'azure/raw-logs'). Empty = keep original blob name."
  type        = string
  default     = ""
}

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
  description = "Days after which mirrored objects are deleted from the created S3 bucket (originals stay in Azure). Defaults to 7: the mirrored copy is a short-lived buffer for Scanner to index, not a permanent duplicate of your Azure data. Set 0 to retain indefinitely. Only applies when this module creates the bucket."
  type        = number
  default     = 7

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

variable "function_app_name" {
  description = "Override name for the mirror function app (default: {name}-mirror-{suffix}; globally unique)"
  type        = string
  default     = ""
}

variable "function_storage_account_name" {
  description = "Override name for the function app's backing storage account (default: {squeezed-name}mfn{suffix})"
  type        = string
  default     = ""
}

variable "managed_identity_name" {
  description = "Override name for the user-assigned managed identity (default: {name}-mirror-mi-{suffix})"
  type        = string
  default     = ""
}

variable "system_topic_name" {
  description = "Override name for the Event Grid system topic on the source account (default: {name}-mirror-topic-{suffix}; only used when create_system_topic = true)"
  type        = string
  default     = ""
}

variable "dlq_container_name" {
  description = "Override name for the dead-letter blob container (default: mirror-dead-letter)"
  type        = string
  default     = ""
}

variable "aws_role_name" {
  description = "Override name for AWS IAM role (default: azure-{name}-s3-writer-{suffix})"
  type        = string
  default     = ""
}
