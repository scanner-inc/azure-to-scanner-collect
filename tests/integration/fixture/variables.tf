variable "subscription_id" {
  description = "Azure subscription ID hosting the test deployment (dedicated test subscription!)"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "eastus"
}

variable "aws_account_id" {
  description = "AWS account ID hosting the test deployment (dedicated test account!)"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI profile to use"
  type        = string
}

variable "run_suffix" {
  description = "Short unique suffix for this run (lowercase alphanumeric, e.g. 'a1b2c3'); embeds in every resource name and must be storage-account safe."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{4,8}$", var.run_suffix))
    error_message = "run_suffix must be 4-8 lowercase alphanumeric characters."
  }
}

variable "test_principal_object_id" {
  description = "Object id of the signed-in test principal; granted blob data access on the run's resource group (run.sh passes this automatically). Empty = skip."
  type        = string
  default     = ""
}

variable "runner_ip_cidr" {
  description = "CIDR of the test runner's public IP (run.sh passes this automatically). Allow-listed on the function apps, which otherwise default-deny everything but Event Grid; needed by tests that hit the apps directly (L5, AUTH1). Empty = Event-Grid-only."
  type        = string
  default     = ""
}
