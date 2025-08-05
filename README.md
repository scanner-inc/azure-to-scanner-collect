# azure-to-scanner-collect
Functions and configurations to send Azure logs to Scanner Collect


## Development Notes

### Build for Deploy

In `functions/` run the `build_for_deploy.sh` script to create
`functions/target/deploy.zip`. Azure Resource Manager will use this file for
deployment - referenced in `templates/root_template.json` file.


## Prerequisites

### Azure Permissions Required

To deploy this template, you need the following Azure permissions:

**Quick Setup (Recommended):**
- **Contributor** role on the target Resource Group
- **Contributor** role on the Azure Subscription (required for activity log forwarding)

**Detailed Permissions:**
If your organization requires minimal permissions, you need these specific rights:
- Resource Group: Event Hub, Storage Account, Function App, Managed Identity, Role Assignment, and Deployment Script permissions
- Subscription: Diagnostic Settings permissions for activity log forwarding

**Note:** Subscription-level access is required because Azure Activity Logs are subscription-wide resources.

## Deploy to Azure

**Before deploying:** Ensure you have Contributor access to both your target Resource Group and Azure Subscription.

You can deploy using Azure Resource Manager template by clicking the button
below:

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fscanner-inc%2Fazure-to-scanner-collect%2Fmain%2Ftemplates%2Froot_template.json)
