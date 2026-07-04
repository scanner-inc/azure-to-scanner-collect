# Azure Logs to S3 Pipeline

Automated pipelines that export Azure logs to Amazon S3 so Scanner can index them:

1. **Activity Logs pipeline**: streams the subscription's Activity Logs to S3 with a few minutes of latency
2. **Blob Container Mirroring**: copies new blobs from existing Azure Blob Storage containers to S3 (with key path filtering), never deleting the source; the mirrored S3 copy expires after 7 days by default (see [Cost and retention](#cost-and-retention))

Everything is Terraform + Python Azure Functions. Cross-cloud delivery uses OIDC workload identity federation: **no static AWS keys anywhere**.

> **Looking for the old ARM-template collector?** This replaced the original
> ARM templates + Node.js function that HTTP-pushed logs to a Scanner Collect
> URL, preserved at the
> [`legacy-arm-v1` release](https://github.com/scanner-inc/azure-to-scanner-collect/releases/tag/legacy-arm-v1)
> for existing deployments. New deployments should use this repo.

## Overview

The Activity Logs pipeline routes a subscription-scoped diagnostic setting into an Event Hub. An Event Hub–triggered function unrolls the diagnostic `records` envelopes and batches entries into gzipped NDJSON staging blobs; an Event Grid–triggered transfer function ships each to S3, deleting it on success. A timer-triggered sweep retries anything the event path missed.

The mirror pipeline watches an existing (customer-owned) blob container via Event Grid `BlobCreated` events and copies filter-matching blobs to S3, never modifying or deleting the source. Failed deliveries retry with backoff and eventually dead-letter to a container where a monitoring alert fires.

## Architecture

### Activity Logs → S3

```
┌──────────────┐      ┌──────────────┐      ┌──────────────┐      ┌──────────────┐      ┌──────────────┐
│ Subscription │ ───► │  Event Hub   │ ───► │ Batch Fn     │ ───► │ Staging Blob │ ───► │  S3 Bucket   │
│ Diagnostic   │      │              │      │ (unroll +    │      │ Container    │      │  (Target)    │
│ Setting      │      │              │      │  gzip NDJSON)│      │              │      │              │
└──────────────┘      └──────────────┘      └──────────────┘      └──────┬───────┘      └──────────────┘
  Activity Log           Streamed              Batched                   │ BlobCreated         ▲
  entries                events                staging blobs             ▼ (Event Grid)        │
                                                                  ┌──────────────┐             │
                                                                  │ Transfer Fn  │ ────────────┘
                                                                  │ (upload +    │   gzip preserved
                                                                  │  delete)     │
                                                                  └──────────────┘
                                                                         ▲
                                                                         │ Retry stale staging blobs
                                                                  ┌──────────────────┐
                                                                  │  Sweep Fn (timer,│
                                                                  │  every 30 min)   │
                                                                  └──────────────────┘
```

**Expect a slow first hour.** Azure Monitor's diagnostic-setting export has
no delivery SLA: a fresh setting backfills for ~30–45 minutes, then settles
to ~6–9 minutes end to end (observed). That latency is Azure's export hop;
this project's stages add only seconds. If logs seem missing right after
`terraform apply`, wait before debugging.

### Blob Container Mirroring → S3

```
┌──────────────┐      ┌──────────────────┐      ┌──────────────┐      ┌──────────────┐
│ Blob         │ ───► │  Event Grid      │ ───► │  Mirror Fn   │ ───► │  S3 Bucket   │
│ Container    │      │  (BlobCreated,   │      │  (filter +   │      │  (Target)    │
│ (existing)   │      │  per-prefix subs)│      │   copy)      │      │              │
└──────────────┘      └────────┬─────────┘      └──────────────┘      └──────────────┘
  Never deleted            │ retries with backoff,
                           ▼ dead-letters after N attempts
                    ┌──────────────┐      ┌──────────────┐
                    │ Dead-letter  │ ───► │ Azure Monitor│
                    │ container    │      │ alert        │
                    └──────────────┘      └──────────────┘
```

### Key Components

- **Subscription Diagnostic Setting**: Routes Activity Log categories to the Event Hub
- **Event Hub**: Transport for streamed Activity Log events
- **Batch Function** (Event Hub trigger): Unrolls `{"records": [...]}` envelopes, writes gzip NDJSON staging blobs named `{log_prefix}/YYYY/MM/DD/hh/mm_ssZ_<id>.json.gz`
- **Transfer Function** (Event Grid trigger): Streams each staging blob to S3 preserving gzip, deletes it on success
- **Sweep Function** (timer trigger): Retries staging blobs older than `age_threshold_minutes` that the event path missed
- **Mirror Function** (Event Grid trigger): Copies filter-matching blobs from a monitored container to S3, never deletes the source
- **Workload Identity Federation**: Managed identity → Entra ID OIDC token → AWS `AssumeRoleWithWebIdentity` (no static keys)
- **S3 Target Bucket**: Final destination with versioning and encryption

## Features

- **Flexible S3 Configuration**: Create a new S3 bucket with a custom name, use an existing bucket, or let Terraform auto-generate a bucket name
- **Scanner Integration**: Optional configuration to automatically set up S3 notifications and IAM policies for Scanner indexing
- **Efficient Compression**: Log batches are gzipped once and streamed to S3 without re-compression; already-compressed customer files are copied byte-for-byte
- **Automatic Recovery**: Timer-driven sweep retries failed Activity Log transfers; Event Grid retry + dead-letter + alerting covers the mirror path
- **Blob Container Mirroring**: Monitor existing containers and copy new blobs (with customizable key path filtering) to S3 so Scanner can index raw logs already landing in Azure; see [Blob Container Mirroring](#blob-container-mirroring-index-raw-logs-from-your-storage-accounts)

## Azure → AWS Authentication

Functions authenticate to AWS without any stored secrets:

1. Each pipeline gets a **user-assigned managed identity**.
2. The shared module creates a dedicated **Entra app registration** whose `api://<client_id>` identifier URI serves as the token audience (Entra will not mint tokens for arbitrary audience strings, and AWS STS rejects Entra **v2** tokens, so the well-known `api://AzureADTokenExchange` audience does NOT work; a plain app registration issues v1 tokens, which STS accepts).
3. The function requests a managed-identity token for that audience. The resulting v1 token has issuer `https://sts.windows.net/<tenant_id>/`, `aud` = the identifier URI, and `sub` = the managed identity's principal id.
4. The shared module creates an **AWS IAM OIDC identity provider** for that issuer.
5. The function calls `sts:AssumeRoleWithWebIdentity`; the role's trust policy pins the token's `aud` **and** `sub`, so only that specific identity can assume the role.
6. The role's only permission is `s3:PutObject/GetObject/HeadObject/ListBucket` on the target bucket.

AWS allows one OIDC provider per issuer URL per account. If this project is deployed more than once into the same AWS account + tenant, pass the first deployment's provider ARN and audience via the shared module's `existing_oidc_provider_arn` + `existing_token_audience`.

### How Event Grid delivery is authenticated

Unlike AWS, where S3 → Lambda invocation flows through AWS's internal API
plane and Lambda has no public URL, every Azure Function app has a public
hostname and Event Grid *pushes* events to it over HTTPS. The pipelines
defend that endpoint in layers:

1. **TLS**: all delivery is HTTPS (`https_only = true`).
2. **Per-function system key**: the `azure_function_endpoint` subscription
   type makes Event Grid's resource provider fetch the Functions host's Event
   Grid extension system key through ARM at subscription-creation time (hence
   creating the subscription requires RBAC on the function app) and present it
   on every delivery (`?code=<secret>`). The host rejects requests without a
   valid key with 401. This is the actual authentication.
3. **Network default-deny**: App Service access restrictions allow only the
   `AzureEventGrid` service tag; everything else is dropped before the
   runtime. That tag covers *all* Azure customers' Event Grid egress IPs, so
   it narrows exposure from "the internet" to "Event Grid traffic"; the
   system key remains the layer that authenticates *our* subscriptions. The
   SCM (Kudu) site keeps its own credential-gated access, so zip deploys keep
   working.

To let other sources reach a function app's runtime host (e.g. a CI runner
calling the Functions admin API), pass `additional_allowed_cidrs` to the
pipeline module.

## Prerequisites

- Terraform >= 1.9
- Azure CLI (`az`), logged in
- AWS CLI (`aws`)
- An Azure subscription; the deploying principal needs **User Access Administrator** or equivalent for the managed identities' role assignments, and the ability to **create an Entra app registration** (default for tenant members unless restricted; otherwise have an admin pre-create it and pass `existing_token_audience`)
- **Activity Logs pipeline only**: **subscription Contributor**, because its diagnostic setting is subscription-scoped. Mirror-only deployments just need Contributor on the resource groups involved (including the source storage account's)
- AWS account with permissions to create IAM roles, the OIDC provider, and S3 buckets

## Setup

### 1. Configure Variables

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your configuration
```

**Required:** `subscription_id`, `aws_account_id`. Optional: `location` (default `eastus`), `aws_region` (default `us-east-1`), `aws_profile`, `resource_group_name`.

### 2. Configure Your Pipeline(s)

Keep the `shared_azure_resources` module in `main.tf` (resource group, AWS OIDC provider, Log Analytics workspace, function deployment packages; one instance per deployment), then uncomment one or more pipeline modules:

- `activity_logs_pipeline`: Activity Logs to a new S3 bucket
- `activity_logs_to_existing_bucket`: Activity Logs to a pre-existing S3 bucket
- `raw_logs_mirror`: Mirror an existing blob container to a new S3 bucket
- `raw_logs_mirror_to_existing_bucket`: Mirror to a pre-existing S3 bucket

The pipelines are independent: to deploy **only the mirror** (or only
Activity Logs), uncomment just that module. Nothing from the other pipeline
is created, and mirror-only deployments skip the subscription-level
permission entirely (see Prerequisites). To add the other pipeline later,
uncomment it and re-run `terraform apply`.

See `main.tf` for detailed examples with inline documentation.

### 3. Deploy

```bash
terraform init
terraform plan
terraform apply
```

Each pipeline module prints `test_instructions` output describing how to verify it end to end.

### Activity Logs Module Options

**Required:** `name`, `shared_azure_resources`, `subscription_id`, `aws_account_id`

**Common options:**

| Variable | Default | Description |
|---|---|---|
| `log_categories` | all 8 categories | Activity Log categories forwarded (Administrative, Security, ServiceHealth, Alert, Recommendation, Policy, Autoscale, ResourceHealth) |
| `log_prefix` | `azure/activity` | Key prefix for staging blobs and S3 objects |
| `s3_bucket_name` / `existing_s3_bucket_name` | auto-generated | Choose one; neither = auto-generated name |
| `s3_expiration_days` | `0` (keep forever) | Expire S3 objects after N days (created bucket only) |
| `sweep_schedule` | every 30 min | NCRONTAB schedule for the sweep function |
| `age_threshold_minutes` | `30` | Staging blobs older than this are retried by the sweep |
| `eventhub_partition_count` | `4` | Event Hub partitions (throughput knob) |
| `functions_plan_sku` | `Y1` (Consumption) | Use `EP1` if cold starts matter |
| `additional_allowed_cidrs` | `[]` (Event-Grid-only) | Extra CIDRs allowed through the function app's default-deny inbound restrictions |
| `scanner_sns_topic_arn` + `scanner_role_arn` | - | Scanner integration (created bucket only) |

Every resource name can also be overridden individually (`eventhub_namespace_name`, `staging_storage_account_name`, `function_app_name`, `aws_role_name`, ...); see `modules/activity-logs-to-s3-pipeline/variables.tf`.

### Mirror Module Options

**Required:** `name`, `shared_azure_resources`, `aws_account_id`, `source_storage_account_name`, `source_storage_account_resource_group`, `source_container_name`

**Common options:**

| Variable | Default | Description |
|---|---|---|
| `key_prefixes` | `[]` (all) | Server-side prefix filtering: one Event Grid subscription per prefix (max 10) |
| `key_include_regex` | `""` (all) | Only copy blobs matching this regex (Python `re.search`) |
| `key_exclude_regex` | `""` (none) | Skip blobs matching this regex |
| `s3_key_prefix` | `""` | Prefix prepended to blob names in S3 |
| `s3_bucket_name` / `existing_s3_bucket_name` | auto-generated | Choose one |
| `s3_expiration_days` | `7` | Expire mirrored S3 objects after N days; `0` = keep forever (created bucket only) |
| `max_delivery_attempts` | `30` | Event Grid delivery attempts before dead-lettering |
| `event_ttl_minutes` | `1440` | Event time-to-live before dead-lettering |
| `alert_email` | `""` | Email notified when events dead-letter (alert rule exists either way) |
| `create_system_topic` | `true` | Set `false` + `existing_system_topic_name` if the storage account already has an Event Grid system topic |
| `additional_allowed_cidrs` | `[]` (Event-Grid-only) | Extra CIDRs allowed through the function app's default-deny inbound restrictions |

## Blob Container Mirroring: Index Raw Logs from Your Storage Accounts

One module instance per monitored container. For buckets this module creates, the mirrored copy in S3 expires after 7 days by default, so it acts as a short-lived buffer rather than a permanent duplicate of your Azure data (see [Cost and retention](#cost-and-retention)). Semantics:

- **Source blobs are NEVER deleted or modified.** The mirror function has read-only (`Storage Blob Data Reader`) access.
- **All configured key filters must pass** for a blob to be copied. Prefix filtering happens server-side (Event Grid `subject_begins_with`, one subscription per prefix), so non-matching blobs never invoke the function; regexes apply in the function.
- **First write wins**: an S3 key that already exists is never re-uploaded, even if the source blob was overwritten. Scanner indexes each S3 key exactly once, so a re-copy would never be re-indexed; this also makes Event Grid redeliveries idempotent.
- **Retries + dead-letter**: transient failures (e.g. S3 unavailable) make the function raise, so Event Grid redelivers with exponential backoff for up to `max_delivery_attempts` attempts / `event_ttl_minutes` minutes, then writes the event to the dead-letter container. An Azure Monitor metric alert fires on any dead-lettered event (optionally emailing `alert_email`).
- **Replay**: dead-lettered events are JSON blobs naming the source blob that failed. After fixing the cause, re-copy those blobs (e.g. re-upload them, or run a one-off script); the function is idempotent.
- **One system topic per storage account** (Azure platform constraint): if the account already has one, set `create_system_topic = false` and pass `existing_system_topic_name`. This module's event subscriptions are additive and won't disturb existing ones.

### Cost and retention

**Retention.** For buckets this module creates, mirrored objects expire from S3 after 7 days by default (`s3_expiration_days`), so S3 is a temporary buffer for Scanner to index rather than a permanent copy of your Azure data. Set `s3_expiration_days = 0` to keep objects indefinitely, or point the pipeline at an existing bucket and manage its lifecycle yourself. Source blobs in Azure are never touched.

**Transfer cost.** Logs move compressed, so throughput is smaller than it looks: 1 TB/day of raw logs is roughly 100 GB/day compressed. Azure egress runs about $0.087/GB (less at higher volume) and S3 ingestion is free, so 100 GB/day works out to roughly $9/day (about $260/month, $3,200/year).

**Storage cost.** With the default 7-day retention, the mirror bucket never holds more than about 700 GB (100 GB/day for 7 days) at 1 TB/day of raw logs. At S3 Standard rates (about $0.023/GB per month), that steady state is roughly $16/month (about $0.50/day, $190/year). Because objects expire, storage stays flat rather than growing forever.

## Compression Behavior

The transfer/mirror functions apply the same compression contract as the GCP pipeline:

| Source blob | Transfer behavior | S3 result |
|---|---|---|
| `Content-Encoding: gzip` | Re-gzipped on the fly (the Azure SDK auto-decompresses such downloads; content identical after decompression) | `ContentEncoding: gzip` |
| Already-compressed filename (`.gz`, `.gzip`, `.zip`, `.bz2`, `.zst`, `.snappy`, `.parquet`) | Copied byte-for-byte | No `ContentEncoding` header |
| Everything else | Gzipped on the fly (streaming, constant memory) | `ContentEncoding: gzip` |

S3 object metadata records `source-account`, `source-container`, `source-size`, `original-encoding`, and `transferred-by` (`transfer-function` / `sweep-function` / `mirror-function`).

## Testing

Unit tests (no cloud credentials needed):

```bash
cd modules/shared-azure-resources/function_source
pip install pytest boto3
python -m pytest test_shared.py -v
```

Integration tests (provision real Azure + AWS resources, run end-to-end assertions, tear everything down):

```bash
cd tests/integration
cp env.tfvars.example env.tfvars   # fill in subscription/account details
./run.sh
```

See `docs/INTEGRATION_TEST_PLAN.md` for the full test plan and known platform behaviors.

## Monitoring

- **Function logs**: `az webapp log tail --name <function_app> --resource-group <rg>`, or query Application Insights (each pipeline has its own instance, backed by the shared Log Analytics workspace)
- **Mirror dead-letter alert**: fires when any event lands in the dead-letter container; inspect with `az storage blob list --container-name mirror-dead-letter ...`
- **Staging container depth**: a growing staging container means transfers are failing; check the transfer function's logs and the sweep function's summary lines

## Cleanup

```bash
terraform destroy
```

Set `force_destroy_buckets = true` in `terraform.tfvars` first if the buckets contain data. Note the subscription diagnostic setting and any role assignments on customer-owned storage accounts are removed too; source containers and their blobs are untouched.

## Cost

For typical Activity Log volumes:

- **Event Hub namespace** (Standard, 1 TU): ~$22/month, the dominant fixed cost
- **Function apps** (Consumption): pennies at Activity Log scale; scales with mirror volume
- **Storage**: staging blobs are deleted after transfer; function-backing accounts are tiny
- **S3 + egress**: standard S3 PUT/storage rates plus Azure→AWS egress (~$0.087/GB)

The mirror module caps S3 storage growth by default: mirrored objects expire after 7 days (`s3_expiration_days = 7`; see [Cost and retention](#cost-and-retention)). The Activity Logs module defaults to keeping objects forever, since S3 holds the only copy of those logs; set its `s3_expiration_days` if you want them to expire once Scanner has indexed them.
