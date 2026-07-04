# Root-level variables
# These can be used by multiple module instances

# Azure Configuration
variable "subscription_id" {
  description = "Azure Subscription ID"
  type        = string
}

variable "resource_group_name" {
  description = "Name of the resource group created for all pipeline resources"
  type        = string
  default     = "scanner-collect-rg"
}

variable "location" {
  description = "Azure region for all resources"
  type        = string
  default     = "eastus"
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

variable "aws_profile" {
  description = "AWS CLI profile to use (optional, defaults to default profile)"
  type        = string
  default     = null
}

# Global Configuration (shared across all pipelines)
variable "force_destroy_buckets" {
  description = "Allow deletion of non-empty buckets (useful for testing/development)"
  type        = bool
  default     = false
}

# Scanner Integration (optional, shared across all pipelines)
variable "scanner_sns_topic_arn" {
  description = "SNS topic ARN for S3 object created notifications (shared across pipelines)"
  type        = string
  default     = ""
}

variable "scanner_role_arn" {
  description = "Scanner role ARN to grant S3 read permissions (shared across pipelines)"
  type        = string
  default     = ""
}
