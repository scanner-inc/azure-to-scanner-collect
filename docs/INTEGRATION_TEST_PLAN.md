# Integration Test Plan

End-to-end tests for both pipelines against **real Azure and AWS accounts**;
no emulators. Mirrors the harness in `gcp-to-scanner-collect` (same
architecture: one apply per session, run-suffix namespacing, bounded polling,
settle canaries, trap-based destroy, post-destroy leftover sweep).

## Objectives

1. Each pipeline delivers end to end: events/blobs in → correctly encoded S3
   objects with the documented metadata contract.
2. Recovery paths work: the sweep function (Activity Logs), Event Grid retry +
   dead-letter (mirror).
3. Terraform contract holds: outputs match reality, plans are idempotent,
   destroy leaves nothing behind.
4. No leaked resources: everything is namespaced by a random run suffix in one
   run-suffixed resource group; `run.sh` fails loudly if destroy leaves
   anything.

## Environments

Use **dedicated test accounts**: the fixture creates a subscription-scoped
diagnostic setting and real AWS IAM/S3 resources. Configure via
`tests/integration/env.tfvars` (gitignored; copy `env.tfvars.example`).

Concurrency limits:
- **One run at a time per (AWS account, Entra tenant)**: the AWS IAM OIDC
  provider URL (`sts.windows.net/<tenant>/`) is unique per AWS account, and the
  shared module creates/destroys it.
- Azure caps activity-log diagnostic settings at five per subscription, further
  bounding concurrent runs.

## Harness Architecture

```
run.sh
  ├─ preflight: terraform >= 1.9, az login session + subscription match,
  │             AWS SSO session, resource providers registered,
  │             runner public-IP detection (allow-listed on the function apps)
  ├─ terraform -chdir=fixture apply     (~10-20 min)
  ├─ pytest -m "not slow"               (settle canaries first, then tests)
  └─ trap EXIT: terraform destroy + leftover sweep (RG, storage accounts,
                S3 buckets bearing the run suffix)
```

- `fixture/` instantiates the real modules under test (never copies), every
  name embedding `run_suffix`. All Azure resources live in the one
  `it-<suffix>-rg` resource group, so "RG gone" ⇒ cleanup complete (storage
  accounts also get a global-namespace check).
- `conftest.py` reads all configuration from `terraform output -json`; tests
  never hardcode environment specifics.
- **Bounded polling everywhere** (`wait_for`); the only fixed sleeps are the
  negative-control grace period and propagation retry loops.
- `./run.sh --keep-fixture` keeps the fixture for debugging;
  `./run.sh --destroy-only --run-suffix <sfx>` tears down a kept run (also use
  this after a killed run, which can't fire the EXIT trap).
- Live logging shows only the harness's own progress lines (`itest` logger);
  SDK loggers are quieted to WARNING. `./run.sh --verbose` restores full
  Azure/AWS SDK logging. `./run.sh --help` documents the full interface.

### Fixture matrix

| Instance | Module | Configuration | Purpose |
|---|---|---|---|
| `activity_logs` | activity-logs-to-s3-pipeline | created S3 bucket, `s3_expiration_days=7`, `age_threshold_minutes=0`, prefix `azure/itest` | L-tests; sweep age 0 so the recovery test needn't wait |
| `mir_new` | blob-container-to-s3-pipeline | fixture-created source account+container, all three key filters, created S3 bucket, `s3_expiration_days=7`, prefix `blob/mirror` | M-tests incl. filter negatives |
| `mir_ex` | blob-container-to-s3-pipeline | second fixture-created source account, **no filters**, fixture-created "existing" S3 bucket, `max_delivery_attempts=3` / `event_ttl_minutes=5` | M9 (existing bucket, no lifecycle), DL1 (bounded dead-letter), multi-instance coexistence (second system topic) |

### Settle canaries (autouse, session-scoped)

Every freshly-created delivery mechanism is warmed before tests count on it:

1. **Mirror path**: canary blobs re-uploaded into `mir_new`'s source until one
   reaches S3. Absorbs Event Grid subscription propagation, function cold
   start, RBAC propagation, and the first STS `AssumeRoleWithWebIdentity` from
   a brand-new federation setup.
2. **Staging→transfer path**: canary gzip-NDJSON blobs uploaded straight into
   the staging container until one reaches S3.
3. **Event Hub path**: synthetic activity-log envelopes sent until **2
   consecutive** canaries arrive in S3 end to end (a fresh consumer group /
   newly-indexed trigger can drop or delay the first events).

Stranded canary staging blobs are deleted afterward so the drain test isn't
polluted.

## Test matrix

Deterministic activity-log tests **inject synthetic events into the Event
Hub**, the analog of the GCP suite writing via the Cloud Logging API. The
diagnostic-setting hop is platform plumbing with no project code and
multi-minute unbounded latency; it gets one slow opt-in test.

Three tests are `@pytest.mark.slow` (opt-in via `./run.sh
--include-slow-tests`; `--only-slow-tests` runs just those three, e.g. against
a kept fixture): M12, DL1, and A-REAL. They are correct but bounded by Azure
clocks we cannot tune (Event Grid retry cadence, ~5-min dead-letter flush,
diagnostic-setting latency), adding ~20 min. Run them before releases or after
touching retry / dead-letter / diagnostic wiring. The default suite still
covers all happy paths, filters, the compression contract, sweep recovery (L5
triggers the sweep on demand, so it is fast), and the Terraform contract.

| ID | File | Asserts |
|---|---|---|
| L1 | test_activity_logs_pipeline | 20 marked events all reach S3 (at-least-once; duplicates legal) |
| L2 | 〃 | `ContentEncoding: gzip`, `ContentType: application/x-ndjson`, `transferred-by` metadata |
| L3 | 〃 | staging container drains (no blob older than 3 min) |
| A-UNROLL | 〃 | one message with `records[5]` → 5 separate NDJSON lines (envelope unrolled) |
| L5 | 〃 | disable transfer fn → strand staging blob → invoke sweep via admin API while broken → lands with `transferred-by: sweep-function`, staging copy deleted |
| A-REAL | 〃 (`@pytest.mark.slow`, opt-in) | some real exported Activity Log event (operationName + category) reaches S3 within 30 min; deliberately not one specific event, since a fresh setting's out-of-order backfill makes "my event within N minutes" a coin flip (two observed timeouts), while any config error breaks backfilled and fresh events alike |
| M1/M2 | test_mirror_pipeline | happy path: key mapping, content round-trip, gzip encoding, metadata; source never deleted |
| M3/M4/M5 | 〃 | prefix / exclude-regex / include-regex negatives, each bounded by a positive control uploaded last + grace period |
| M7 | 〃 | `.json.gz` copied byte-for-byte, no ContentEncoding |
| M8 | 〃 | blob with `Content-Encoding: gzip` lands with encoding preserved + content round-trip (SDK auto-decompresses downloads, pipeline re-compresses), `original-encoding` metadata |
| M12 | 〃 (`@pytest.mark.slow`, opt-in) | disable fn → strand → re-enable → Event Grid retry alone recovers (≤15 min; Event Grid's retry schedule is fixed and spaced, no retry-now knob) |
| DL1 | test_dead_letter (`@pytest.mark.slow`, opt-in) | with delivery broken on `mir_ex` (attempts=3, TTL=5 min), an event dead-letters to the DLQ container within ~15 min (dead-letter writes flush ~every 5 min) |
| M9 | test_mirror_existing | unfiltered mirror into pre-existing S3 bucket; content round-trips; `NoSuchLifecycleConfiguration` on the existing bucket |
| T1 | test_terraform_contract | outputs non-empty + resources exist + everything in the run RG + suffix embedded |
| T1b | 〃 | 7-day lifecycle on both created buckets |
| T1c | 〃 | event subscriptions have dead-letter + retry policy; DLQ container exists; metric alert enabled |
| T1d | 〃 | AWS trust policies pin issuer + `aud` + `sub` = managed identity principal |
| T1e | 〃 | all function apps default-deny inbound with Allow rules only for the AzureEventGrid service tag + the runner IP; SCM site not default-deny |
| AUTH1 | 〃 | an unauthenticated POST to the Event Grid delivery endpoint (from the allow-listed runner) is rejected 401/403; the system key is enforced independently of the network layer |
| T2 | 〃 | `terraform plan -detailed-exitcode` == 0 right after apply |
| T3 | run.sh | post-destroy: no RG / storage account / S3 bucket bearing the suffix |

## Timing budget (approximate)

| Phase | Duration |
|---|---|
| Preflight | ~15 s |
| terraform apply | 10–20 min (function app deploys + Event Hub namespace dominate) |
| Settle canaries | 3–10 min (RBAC + Event Grid propagation dominate) |
| Tests (default, `-m "not slow"`) | ~5–10 min |
| Tests (full, `./run.sh --include-slow-tests`) | ~25–50 min (M12, DL1, and A-REAL wait on Event Grid retry cadence, dead-letter flush, and diagnostic-setting latency; the latter alone is 10–25+ min with no SLA) |
| terraform destroy | 10–15 min (resource group deletion is slow) |
| **Total (default)** | **~30–45 min** |

Cost: < $1/run, dominated by Event Hub Standard namespace hours for the
run's lifetime; Consumption function plans and test data volumes are noise.

## Known Platform Behaviors

Each behavior and how the harness compensates:

1. **Event Grid subscription creation → first-delivery latency/drops.** Fresh
   subscriptions can delay or drop the first events. *Compensation:* settle
   canaries re-upload until an object reaches S3; M9 uses the same loop for the
   un-settled `mir_ex` subscription.
2. **RBAC role-assignment propagation (minutes), in multiple directions:**
   managed identity → storage, test principal → storage data plane, and the
   first STS assume from a new OIDC setup can all lag or reject.
   *Compensation:* settle canaries + `wait_for` absorb it.
3. **Function app deploy → trigger sync/cold start.** Kudu zip deploy with Oryx
   remote build must finish and index triggers before Event Grid can
   validate/deliver, and the app cold-starts. *Compensation:* Terraform orders
   Event Grid subscriptions after the function app; canaries warm cold start.
4. **`AzureWebJobs.<fn>.Disabled` takes effect lazily** (app-setting change →
   restart → trigger sync). *Compensation:* L5/M12/DL1 retry upload-and-check
   until a blob demonstrably strands, mirroring the GCP suite's "IAM revocation
   propagates lazily" loop.
5. **Subscription-scoped diagnostic setting: whole-subscription firehose, no
   delivery SLA, ~5-per-subscription cap. A fresh setting spends its first
   ~30-45 min backfilling recent events out of order; events emitted in that
   window can take 25+ min to export. Steady-state latency ~6-9 min.**
   *Compensation:* deterministic tests inject at the Event Hub; A-REAL is
   slow/opt-in with a 30-min budget; the cap bounds concurrent runs.
6. **The diagnostic-setting EXPORT schema strips request/response bodies**
   (unlike the Activity Log API view of the same event), so nothing a test
   writes (e.g. a tag value) survives into S3. *Compensation:* A-REAL asserts
   on export-schema fields (operationName + category), not injected content.
7. **Event Hub consumer cold start.** A fresh consumer group takes time to
   establish checkpoints; first events may lag. *Compensation:* settle canary 3
   requires 2 consecutive end-to-end successes.
8. **Storage-account names: global namespace, ≤24 chars, lowercase
   alphanumerics only.** *Compensation:* run suffix is lowercase hex; account
   names are `it<suffix><role>`; on a rare global collision, re-run with a fresh
   suffix.
9. **Resource-group deletion is slow (5–15 min).** *Compensation:* the EXIT
   trap tolerates it; the leftover sweep fails loudly rather than leaking
   silently.
10. **Event Grid retry cadence is spaced (10s, 30s, 1m, 5m, 10m, …) and
    dead-letter writes are batched (~5 min flush delay).** *Compensation:* M12
    has a 15-min budget; DL1 runs against a subscription with
    `max_delivery_attempts=3` / `event_ttl_minutes=5` and a 15-min budget.
11. **One Event Grid system topic per storage account.** The fixture uses two
    separate source accounts so each mirror instance gets its own topic; the
    `create_system_topic=false` attach path is covered by module validation,
    not a live test (would require a pre-existing topic).
12. **Function apps default-deny inbound (AzureEventGrid service tag only).**
    The Functions admin API (used by L5 and the AUTH1 probe) sits behind the
    same access restrictions. *Compensation:* run.sh detects the runner's
    public IP at preflight and passes it as `runner_ip_cidr`, which the fixture
    allow-lists via each module's `additional_allowed_cidrs`. A mid-run NAT IP
    change would break only L5/AUTH1, with clear messages.
13. **Tag drift cascades into resource replacement.** An externally-added tag
    on a managed resource makes the next plan "change" it, which defers
    dependent modules' data-source reads and cascades known-after-apply
    replacements; replacing a system topic silently drops its event
    subscriptions. (An earlier A-REAL variant tagged the fixture RG and broke
    reuse this way.) *Compensation:* tests no longer mutate managed resources;
    the shared module's RG and the fixture's source storage accounts carry
    `ignore_changes = [tags]` as defense anyway.

## Out of scope

- A real Scanner tenant (no indexing assertions; S3 arrival + contract only).
- CI automation (manual/local runs; the harness is CI-shaped if wanted later).
- Load/scale testing.
