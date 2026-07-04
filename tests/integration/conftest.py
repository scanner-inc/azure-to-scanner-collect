"""
Shared fixtures for the integration test suite.

Assumes the fixture/ Terraform is already applied (run.sh does this); all
config comes from `terraform output -json`, never hardcoded.
"""
import gzip
import json
import logging
import os
import subprocess
import time
import uuid
from pathlib import Path

import boto3
import pytest
import requests
from azure.core.exceptions import ResourceNotFoundError
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient, ContentSettings


def pytest_configure(config):
    # log_cli (pytest.ini) streams every logger at INFO, including the Azure
    # SDK's per-call request/response header dumps, which bury the harness's
    # progress lines. Quiet the SDK/transport loggers unless `./run.sh
    # --verbose` (VERBOSE=1) asks for them; warnings/errors still pass.
    if os.environ.get("VERBOSE", "0") != "1":
        for name in ("azure", "urllib3", "botocore", "boto3", "msal", "uamqp"):
            logging.getLogger(name).setLevel(logging.WARNING)


INTEGRATION_DIR = Path(__file__).parent
FIXTURE_DIR = INTEGRATION_DIR / "fixture"
ENV_TFVARS = INTEGRATION_DIR / "env.tfvars"

CANARY_STAGING_PREFIX = "azure/itest/canary/"

# Live progress (streamed by pytest's log_cli config in pytest.ini)
log = logging.getLogger("itest")


# ---------- Terraform outputs ----------

@pytest.fixture(scope="session")
def tf():
    """Terraform outputs of the applied fixture, as a flat dict."""
    result = subprocess.run(
        ["terraform", f"-chdir={FIXTURE_DIR}", "output", "-json"],
        capture_output=True, text=True, check=True,
    )
    outputs = json.loads(result.stdout)
    if not outputs:
        pytest.fail("No terraform outputs found - has the fixture been applied? (run.sh does this)")
    return {k: v["value"] for k, v in outputs.items()}


# ---------- Cloud clients ----------

@pytest.fixture(scope="session")
def azure_credential():
    return DefaultAzureCredential()


@pytest.fixture(scope="session")
def blob_service(azure_credential):
    """Factory: BlobServiceClient for a storage account by name (cached)."""
    clients = {}

    def get(account_name):
        if account_name not in clients:
            clients[account_name] = BlobServiceClient(
                account_url=f"https://{account_name}.blob.core.windows.net",
                credential=azure_credential,
            )
        return clients[account_name]

    return get


@pytest.fixture(scope="session")
def s3(tf):
    session = boto3.Session(profile_name=tf["aws_profile"], region_name=tf["aws_region"])
    return session.client("s3")


@pytest.fixture(scope="session")
def send_events(tf):
    """Factory: send a list of JSON-serializable payloads to the Activity
    Logs Event Hub (each payload becomes one Event Hub message)."""
    from azure.eventhub import EventData, EventHubProducerClient

    def send(payloads):
        producer = EventHubProducerClient.from_connection_string(
            tf["al_eventhub_send_connection"], eventhub_name=tf["al_eventhub_name"]
        )
        with producer:
            batch = producer.create_batch()
            for payload in payloads:
                batch.add(EventData(json.dumps(payload)))
            producer.send_batch(batch)

    return send


# ---------- Helpers ----------

def wait_for(description, predicate, timeout, interval=5, heartbeat=30):
    """Poll predicate until truthy or timeout (seconds), returning its value.
    Logs a heartbeat every `heartbeat` seconds so long waits stay visible."""
    start = time.monotonic()
    deadline = start + timeout
    next_heartbeat = start + heartbeat
    last_error = None
    while time.monotonic() < deadline:
        try:
            value = predicate()
            if value:
                elapsed = time.monotonic() - start
                if elapsed >= heartbeat:
                    log.info("done after %.0fs: %s", elapsed, description)
                return value
        except Exception as e:  # transient API errors count as "not yet"
            last_error = e
        if time.monotonic() >= next_heartbeat:
            log.info("still waiting (%.0fs/%ss): %s",
                     time.monotonic() - start, timeout, description)
            next_heartbeat += heartbeat
        time.sleep(interval)
    detail = f" (last error: {last_error})" if last_error else ""
    raise AssertionError(f"Timed out after {timeout}s waiting for: {description}{detail}")


def s3_object_exists(s3, bucket, key):
    try:
        s3.head_object(Bucket=bucket, Key=key)
        return True
    except s3.exceptions.ClientError as e:
        if e.response["Error"]["Code"] == "404":
            return False
        raise


def s3_get_decompressed(s3, bucket, key):
    """Fetch an S3 object, gunzipping if Content-Encoding: gzip. Returns (bytes, response)."""
    resp = s3.get_object(Bucket=bucket, Key=key)
    body = resp["Body"].read()
    if resp.get("ContentEncoding") == "gzip":
        body = gzip.decompress(body)
    return body, resp


def s3_list_keys(s3, bucket, prefix):
    keys = []
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        keys.extend(obj["Key"] for obj in page.get("Contents", []))
    return keys


def az(args, check=True):
    """Run an az CLI command, returning the CompletedProcess."""
    result = subprocess.run(["az", *args], capture_output=True, text=True)
    if check and result.returncode != 0:
        raise RuntimeError(f"az {' '.join(args)} failed:\n{result.stderr[-2000:]}")
    return result


def upload_blob(blob_service, account, container, name, data, content_type=None,
                content_encoding=None):
    """Upload a blob, optionally with content settings."""
    settings = None
    if content_type or content_encoding:
        settings = ContentSettings(content_type=content_type, content_encoding=content_encoding)
    client = blob_service(account).get_blob_client(container=container, blob=name)
    client.upload_blob(data, overwrite=True, content_settings=settings)


def blob_exists(blob_service, account, container, name):
    try:
        blob_service(account).get_blob_client(container=container, blob=name).get_blob_properties()
        return True
    except ResourceNotFoundError:
        return False


def list_blobs(blob_service, account, container, prefix=None):
    """List blob properties in a container (optionally under a prefix)."""
    cc = blob_service(account).get_container_client(container)
    return list(cc.list_blobs(name_starts_with=prefix))


def staging_ndjson_gzip(payload_lines):
    """Build a gzip NDJSON body the way the batch function does."""
    ndjson = b"".join(json.dumps(line).encode() + b"\n" for line in payload_lines)
    return gzip.compress(ndjson)


def upload_staging_blob(blob_service, tf, name, payload_lines):
    """Upload a gzip NDJSON blob into the staging container with the same
    content settings the batch function uses."""
    upload_blob(
        blob_service, tf["al_staging_account"], tf["al_staging_container"], name,
        staging_ndjson_gzip(payload_lines),
        content_type="application/x-ndjson", content_encoding="gzip",
    )


# ---------- Function control (disable / enable / invoke) ----------

def set_function_disabled(tf, app_name, function_name, disabled):
    """Disable/enable one function via the AzureWebJobs.<fn>.Disabled app
    setting (the app restarts; propagation is non-deterministic, so callers
    retry until the change bites).

    Enabling DELETES the setting rather than writing "0": a leftover setting
    is invisible to Terraform and would break the T2 plan-idempotency test."""
    if disabled:
        az([
            "functionapp", "config", "appsettings", "set",
            "--name", app_name, "--resource-group", tf["resource_group"],
            "--settings", f"AzureWebJobs.{function_name}.Disabled=1",
            "--output", "none",
        ])
    else:
        az([
            "functionapp", "config", "appsettings", "delete",
            "--name", app_name, "--resource-group", tf["resource_group"],
            "--setting-names", f"AzureWebJobs.{function_name}.Disabled",
            "--output", "none",
        ])


def trigger_function(tf, app_name, function_name, timeout=120):
    """Invoke a function on demand via the Functions admin API, e.g. to run
    the timer-triggered sweep now instead of waiting for its schedule."""
    master_key = az([
        "functionapp", "keys", "list",
        "--name", app_name, "--resource-group", tf["resource_group"],
        "--query", "masterKey", "-o", "tsv",
    ]).stdout.strip()
    if not master_key:
        raise RuntimeError(f"could not fetch master key for {app_name}")

    url = f"https://{app_name}.azurewebsites.net/admin/functions/{function_name}"
    resp = requests.post(
        url, json={"input": ""},
        headers={"x-functions-key": master_key},
        timeout=timeout,
    )
    if resp.status_code not in (200, 202):
        raise RuntimeError(
            f"admin invoke of {function_name} failed: HTTP {resp.status_code} {resp.text[:500]}"
        )


def function_logs_hint(tf, app_output_key):
    """A copy-pasteable command for debugging a failed arrival."""
    return (
        f"debug: az webapp log tail --name {tf[app_output_key]} "
        f"--resource-group {tf['resource_group']}"
    )


def unique_marker():
    return uuid.uuid4().hex[:12]


# ---------- Post-apply settle canaries ----------

def settle_blob_trigger(blob_service, account, container, make_key, upload_kwargs,
                        s3, s3_bucket, dest_key_of, label, timeout=600):
    """
    A freshly-created path may drop its first events: Event Grid
    subscriptions delay/drop pre-propagation, apps cold-start, RBAC
    propagates lazily, and the first STS AssumeRoleWithWebIdentity from new
    federation can be rejected. Push canary blobs through until one reaches
    S3, re-uploading every ~75s (a fresh blob gives a fresh event).
    """
    log.info("settling %s path (uploading canaries until one reaches S3)...", label)
    start = time.monotonic()
    deadline = start + timeout
    attempt = 0
    while time.monotonic() < deadline:
        attempt += 1
        key = make_key(attempt)
        log.info("%s canary attempt %d: %s", label, attempt, key)
        upload_blob(blob_service, account, container, key, **upload_kwargs)
        try:
            wait_for(
                f"{label} canary {key} to reach S3",
                lambda k=key: s3_object_exists(s3, s3_bucket, dest_key_of(k)),
                timeout=75,
            )
            log.info("%s path settled after %d attempt(s), %.0fs",
                     label, attempt, time.monotonic() - start)
            return  # events are flowing
        except AssertionError:
            continue
    pytest.fail(f"{label} canary never reached S3 within {timeout}s - events are not flowing")


def settle_eventhub_path(tf, blob_service, send_events, s3, required_successes=2,
                         timeout=900):
    """Warm the Event Hub -> batch -> staging -> transfer -> S3 path end to
    end. A fresh consumer needs time to checkpoint and the host to index the
    trigger, so require consecutive successes before trusting the path."""
    fetched = {}

    def marker_in_s3(marker):
        for key in s3_list_keys(s3, tf["al_s3_bucket"], tf["al_s3_prefix"]):
            if key not in fetched:
                body, _ = s3_get_decompressed(s3, tf["al_s3_bucket"], key)
                fetched[key] = body.decode(errors="replace")
        return any(marker in text for text in fetched.values())

    def diagnose_staging(marker):
        """Which leg failed? Look for the marker in the staging container."""
        try:
            for props in list_blobs(blob_service, tf["al_staging_account"],
                                    tf["al_staging_container"]):
                content = blob_service(tf["al_staging_account"]).get_blob_client(
                    container=tf["al_staging_container"], blob=props.name
                ).download_blob().readall()
                try:
                    content = gzip.decompress(content)
                except OSError:
                    pass
                if marker.encode() in content:
                    return (f"marker IS in staging blob {props.name} - the batch "
                            "function consumed it but the staging->S3 transfer leg is broken")
            return ("marker NOT in staging - the batch function never consumed the "
                    "event (Event Hub trigger not firing)")
        except Exception as e:
            return f"(staging diagnosis failed: {e})"

    log.info("settling Event Hub path (need %d consecutive canary deliveries)...",
             required_successes)
    start = time.monotonic()
    successes = 0
    attempt = 0
    last_marker = None
    deadline = start + timeout
    while successes < required_successes:
        if time.monotonic() > deadline:
            pytest.fail(
                f"Event Hub canary: only {successes}/{required_successes} consecutive "
                f"canary events reached S3 within {timeout}s - consumer still settling or "
                f"pipeline broken. Diagnosis: {diagnose_staging(last_marker)}. "
                f"{function_logs_hint(tf, 'al_function_app')}"
            )
        attempt += 1
        last_marker = marker = f"eventhub-canary-{unique_marker()}"
        log.info("Event Hub canary attempt %d (%d/%d consecutive so far)",
                 attempt, successes, required_successes)
        send_events([{"records": [{"itest_canary": marker, "attempt": attempt}]}])
        try:
            # Event Hub -> batch fn -> staging -> Event Grid -> transfer -> S3
            wait_for(f"Event Hub canary {marker} to reach S3",
                     lambda m=marker: marker_in_s3(m), timeout=180, interval=10)
            successes += 1
        except AssertionError:
            successes = 0  # a dropped canary means the path is still settling
    log.info("Event Hub path settled after %d attempt(s), %.0fs",
             attempt, time.monotonic() - start)


@pytest.fixture(scope="session", autouse=True)
def pipelines_settled(tf, blob_service, s3, send_events):
    """Warm every freshly-created delivery mechanism before tests rely on it:
    1. the mirror pipeline's Event Grid -> function path,
    2. the staging container's Event Grid -> transfer function path,
    3. the Event Hub -> batch function path, end to end."""
    marker = unique_marker()

    settle_blob_trigger(
        blob_service, tf["mirror_source_account"], tf["mirror_source_container"],
        lambda n: f"logs/canary/{marker}-{n}.json",
        {"data": b'{"canary": true}\n'},
        s3, tf["mirror_s3_bucket"],
        lambda k: f"{tf['mirror_s3_key_prefix']}/{k}",
        label="mirror",
    )
    settle_blob_trigger(
        blob_service, tf["al_staging_account"], tf["al_staging_container"],
        lambda n: f"{CANARY_STAGING_PREFIX}{marker}-{n}.json.gz",
        {
            "data": staging_ndjson_gzip([{"canary": True}]),
            "content_type": "application/x-ndjson",
            "content_encoding": "gzip",
        },
        s3, tf["al_s3_bucket"],
        lambda k: k,  # the transfer function preserves the staging key in S3
        label="staging transfer",
    )
    settle_eventhub_path(tf, blob_service, send_events, s3)

    # Dropped canary attempts strand in the staging container (nothing deletes
    # them until the sweep); remove them so the staging-drains test is clean
    for props in list_blobs(blob_service, tf["al_staging_account"],
                            tf["al_staging_container"], prefix=CANARY_STAGING_PREFIX):
        blob_service(tf["al_staging_account"]).get_blob_client(
            container=tf["al_staging_container"], blob=props.name
        ).delete_blob()
    log.info("all delivery paths settled; running tests")
