variable "resource_group_name" {
  description = "Name of the resource group to create for all pipeline resources"
  type        = string
  default     = "scanner-collect-rg"
}

variable "location" {
  description = "Azure region for all resources"
  type        = string
  default     = "eastus"
}

variable "existing_oidc_provider_arn" {
  description = "ARN of an existing AWS IAM OIDC identity provider for this Entra tenant (AWS allows only one per issuer URL per account). Empty = create one. Must be set together with existing_token_audience."
  type        = string
  default     = ""

  validation {
    condition     = (var.existing_oidc_provider_arn == "") == (var.existing_token_audience == "")
    error_message = "existing_oidc_provider_arn and existing_token_audience must be set together (the provider's client ID list must contain the audience), or neither."
  }
}

variable "existing_token_audience" {
  description = "Identifier URI (api://...) of an existing Entra app registration to use as the token audience, e.g. from another deployment of this project in the same tenant. Empty = create a dedicated app registration. Must be set together with existing_oidc_provider_arn."
  type        = string
  default     = ""
}

variable "log_analytics_workspace_name" {
  description = "Override name for the shared Log Analytics workspace (default: scanner-collect-logs-{suffix})"
  type        = string
  default     = ""
}
