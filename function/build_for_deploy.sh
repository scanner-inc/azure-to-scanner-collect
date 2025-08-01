# Only need package-lock.json for deployment to Azure
(cd src && npm install --package-lock-only && zip -r ../target/deploy.zip .)
