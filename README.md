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

## Setup Guide

### Step 1: Create Azure HTTP Receiver in Scanner Collect

- Go to the **Collect** tab in your Scanner account
- Create a new **Azure** source with origin set to **HTTP Push**
- Generate a Bearer token: eg. `echo "token_$(uuidgen | tr '[:upper:]' '[:lower:])"`
- Complete the setup with default values
- **Save both the Bearer token and HTTP URL** - you'll need them for Azure deployment

### Step 2: Deploy to Azure

**Before deploying:** Ensure you have Contributor access to both your target Resource Group and Azure Subscription.

1. **Open Deployment:** Click the "Deploy to Azure" button below
2. **Configure Template:**
   - Paste your **Scanner Collect URL** from Step 1
   - Paste your **Scanner Bearer Token** from Step 1
   - Keep **Send Activity Logs** checked to forward Azure Activity Logs
3. **Deploy:** Click "Create" to deploy the resources

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fscanner-inc%2Fazure-to-scanner-collect%2Fmain%2Ftemplates%2Froot_template.json)

Once deployment completes, Azure activity logs will automatically flow to Scanner Collect.
