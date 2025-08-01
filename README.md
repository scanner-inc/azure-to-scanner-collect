# azure-to-scanner-collect
Functions and configurations to send Azure logs to Scanner Collect


## Development Notes

### Build for Deploy

In `functions/` run the `build_for_deploy.sh` script to create
`functions/target/deploy.zip`. Azure Resource Manager will use this file for
deployment - referenced in `templates/root_template.json` file.


## Deploy to Azure

You can deploy using Azure Resource Manager template by clicking the button
below:

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fscanner-inc%2Fazure-to-scanner-collect%2Fmain%2Ftemplates%2Froot_template.json)
