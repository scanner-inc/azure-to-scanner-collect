# Shared Azure resources that only need to exist once per deployment
# This module should be instantiated once, and its outputs passed to all
# pipeline modules

terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
    }
    azuread = {
      source = "hashicorp/azuread"
    }
    aws = {
      source = "hashicorp/aws"
    }
    archive = {
      source = "hashicorp/archive"
    }
    tls = {
      source = "hashicorp/tls"
    }
    random = {
      source = "hashicorp/random"
    }
  }
}

data "azurerm_client_config" "current" {}

# Random suffix for unique naming
resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  tenant_id = data.azurerm_client_config.current.tenant_id

  # Managed identity tokens are Entra ID v1.0 tokens, so their issuer is
  # sts.windows.net/<tenant>/ (not the v2 login.microsoftonline.com issuer).
  # The trailing slash is part of the iss claim and must be preserved.
  oidc_issuer_url = "https://sts.windows.net/${local.tenant_id}/"
}

# ============== Resource Group ==============
# All Azure pipeline resources live in this resource group

resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location

  lifecycle {
    # RG tags aren't ours to manage (operators and the A-REAL test tag it).
    # Without this, an external tag makes the next plan "change" the RG, which
    # defers every dependent module's data-source reads and cascades
    # known-after-apply replacements through the pipelines (system topics get
    # replaced, silently dropping their event subscriptions).
    ignore_changes = [tags]
  }
}

# ============== Token Audience App Registration ==============
# Entra ID won't mint tokens for arbitrary audience strings, so the pipelines'
# managed identities request tokens for a dedicated app registration created
# here. Its api://<client_id> identifier URI becomes the token's aud claim,
# which the AWS trust policies pin.
#
# The app registration defaults to v1 access tokens (issuer
# sts.windows.net/<tenant>/) - REQUIRED: AWS STS rejects Entra v2 tokens
# (verified; the well-known api://AzureADTokenExchange audience yields a v2
# token STS refuses with InvalidIdentityToken despite a valid signature).

resource "azuread_application" "aws_token_audience" {
  count = var.existing_token_audience == "" ? 1 : 0

  display_name = "scanner-collect-aws-${random_id.suffix.hex}"

  lifecycle {
    # identifier_uris is managed by azuread_application_identifier_uri below
    # (setting it here would self-cycle on this app's client_id); without
    # this, every plan tries to remove the URI
    ignore_changes = [identifier_uris]
  }
}

resource "azuread_application_identifier_uri" "aws_token_audience" {
  count = var.existing_token_audience == "" ? 1 : 0

  application_id = azuread_application.aws_token_audience[0].id
  # api://<client_id> is always permitted (custom URI strings can be blocked
  # by tenant policy)
  identifier_uri = "api://${azuread_application.aws_token_audience[0].client_id}"
}

# A service principal must exist in the tenant for the token endpoint to
# issue tokens for this resource
resource "azuread_service_principal" "aws_token_audience" {
  count = var.existing_token_audience == "" ? 1 : 0

  client_id = azuread_application.aws_token_audience[0].client_id
}

locals {
  aws_oidc_audience = var.existing_token_audience != "" ? var.existing_token_audience : "api://${azuread_application.aws_token_audience[0].client_id}"
}

# ============== AWS OIDC Identity Provider ==============
# Lets AWS STS validate Entra ID tokens so the pipelines' managed identities
# can AssumeRoleWithWebIdentity - no static AWS keys anywhere.
#
# AWS allows one OIDC provider per issuer URL per account. If one already
# exists for this tenant (e.g. another deployment of this project in the same
# AWS account), pass its ARN via existing_oidc_provider_arn (and the audience
# it lists via existing_token_audience) instead.

data "tls_certificate" "entra" {
  count = var.existing_oidc_provider_arn == "" ? 1 : 0
  url   = local.oidc_issuer_url
}

resource "aws_iam_openid_connect_provider" "entra" {
  count = var.existing_oidc_provider_arn == "" ? 1 : 0

  url = local.oidc_issuer_url

  # The audience (aud claim) the pipelines' tokens carry
  client_id_list = [local.aws_oidc_audience]

  # Pin the issuer's TLS chain at creation time (AWS no longer relies on
  # thumbprints for trusted CAs, but the API requires a non-empty list)
  thumbprint_list = [for cert in data.tls_certificate.entra[0].certificates : cert.sha1_fingerprint]

  lifecycle {
    # Microsoft's TLS endpoints serve rotating certificate chains, so the data
    # source returns different thumbprints every plan. Without this the
    # provider churns each plan - and since pipeline modules receive the
    # shared resources as one object, that perpetual pending change defers
    # their data-source reads and cascades known-after-apply drift into
    # otherwise-idempotent plans.
    ignore_changes = [thumbprint_list]
  }

  depends_on = [azuread_service_principal.aws_token_audience]
}

locals {
  oidc_provider_arn = var.existing_oidc_provider_arn != "" ? var.existing_oidc_provider_arn : aws_iam_openid_connect_provider.entra[0].arn
}

# ============== Log Analytics Workspace ==============
# Shared workspace backing each pipeline's Application Insights (function
# logs / diagnostics)

resource "azurerm_log_analytics_workspace" "this" {
  name                = var.log_analytics_workspace_name != "" ? var.log_analytics_workspace_name : "scanner-collect-logs-${random_id.suffix.hex}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

# ============== Function Deployment Packages ==============
# Each function app deploys from a zip of the shared function_source dir.
# The per-app entry file is renamed to function_app.py (the required v2
# programming model entry point).

data "archive_file" "activity_logs_package" {
  type        = "zip"
  output_path = "${path.module}/activity_logs_function.zip"

  source {
    content  = file("${path.module}/function_source/activity_logs_function_app.py")
    filename = "function_app.py"
  }

  source {
    content  = file("${path.module}/function_source/shared.py")
    filename = "shared.py"
  }

  source {
    content  = file("${path.module}/function_source/requirements.txt")
    filename = "requirements.txt"
  }

  source {
    content  = file("${path.module}/function_source/host.json")
    filename = "host.json"
  }
}

data "archive_file" "mirror_package" {
  type        = "zip"
  output_path = "${path.module}/mirror_function.zip"

  source {
    content  = file("${path.module}/function_source/mirror_function_app.py")
    filename = "function_app.py"
  }

  source {
    content  = file("${path.module}/function_source/shared.py")
    filename = "shared.py"
  }

  source {
    content  = file("${path.module}/function_source/requirements.txt")
    filename = "requirements.txt"
  }

  source {
    content  = file("${path.module}/function_source/host.json")
    filename = "host.json"
  }
}
