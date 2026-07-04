"""
Activity logs function app: Event Hub -> staging blob container -> S3.

Three functions:

- batch_events: Event Hub trigger. Unrolls the `records` arrays that Azure
  diagnostic settings wrap log entries in, serializes to NDJSON, gzips, and
  writes size-capped staging blobs named
  {LOG_PREFIX}/YYYY/MM/DD/hh/mm_ssZ_<id>.json.gz.
- transfer_staging_blob: Event Grid trigger on staging BlobCreated events.
  Streams the staging blob to S3 (preserving gzip) and deletes it on success.
  Errors are swallowed (not retried by Event Grid) - the sweep function is
  the recovery path.
- sweep_stale_blobs: Timer trigger. Retries any staging blob older than
  AGE_THRESHOLD_MINUTES that the event path missed.

This file is deployed as function_app.py in the activity-logs function app.
"""
import os
from datetime import datetime, timezone, timedelta

import azure.functions as func
from azure.core.exceptions import ResourceNotFoundError

from shared import (
    AzureBlobRef,
    build_staging_blob_name,
    get_blob_service_client,
    get_s3_client,
    gzip_bytes,
    log_structured,
    parse_blob_created_subject,
    records_to_ndjson_batches,
    transfer_blob_to_s3,
    unroll_records,
)

app = func.FunctionApp()


@app.function_name(name="batch_events")
@app.event_hub_message_trigger(
    arg_name="events",
    event_hub_name="%EVENTHUB_NAME%",
    connection="EVENTHUB_CONNECTION",
    cardinality=func.Cardinality.MANY,
)
@app.retry(strategy="exponential_backoff", max_retry_count="5",
           minimum_interval="00:00:04", maximum_interval="00:01:00")
def batch_events(events):
    """Batch Event Hub messages into gzip NDJSON staging blobs.

    The Event Hubs trigger checkpoints after delivery regardless of outcome,
    so a failure alone would drop the batch; the retry policy re-runs a
    failing invocation (with backoff) before the checkpoint advances.
    """
    if not isinstance(events, list):
        events = [events]

    records = []
    for event in events:
        records.extend(unroll_records(event.get_body()))

    if not records:
        log_structured("No records to write after unrolling", event_count=len(events))
        return

    staging_account = os.environ['STAGING_ACCOUNT']
    staging_container = os.environ['STAGING_CONTAINER']
    log_prefix = os.environ.get('LOG_PREFIX', '')

    container_client = get_blob_service_client(staging_account).get_container_client(
        staging_container
    )

    from azure.storage.blob import ContentSettings

    now = datetime.now(timezone.utc)
    written = []
    for batch in records_to_ndjson_batches(records):
        blob_name = build_staging_blob_name(log_prefix, now)
        container_client.upload_blob(
            name=blob_name,
            data=gzip_bytes(batch),
            content_settings=ContentSettings(
                content_type='application/x-ndjson',
                content_encoding='gzip',
            ),
        )
        written.append(blob_name)

    log_structured(
        "Wrote staging blobs",
        event_count=len(events),
        record_count=len(records),
        blobs=written
    )


@app.function_name(name="transfer_staging_blob")
@app.event_grid_trigger(arg_name="event")
def transfer_staging_blob(event: func.EventGridEvent):
    """Transfer a staging blob to S3, then delete it from staging.

    Errors are logged but not raised: the sweep function retries stale
    staging blobs, so Event Grid redelivery is unnecessary (and a poison blob
    would otherwise churn for 24h).
    """
    container_name, blob_name = parse_blob_created_subject(event.subject)
    if not blob_name:
        log_structured(
            "Ignored: not a BlobCreated subject",
            severity='WARNING',
            subject=event.subject
        )
        return

    # Only process blobs from the expected staging container
    expected_container = os.environ.get('STAGING_CONTAINER')
    if container_name != expected_container:
        log_structured(
            "Rejected: unexpected container",
            severity='WARNING',
            container=container_name,
            expected=expected_container,
            object=blob_name
        )
        return

    try:
        staging_account = os.environ['STAGING_ACCOUNT']
        blob_client = get_blob_service_client(staging_account).get_blob_client(
            container=container_name, blob=blob_name
        )
        try:
            blob = AzureBlobRef(blob_client)
        except ResourceNotFoundError:
            log_structured(
                "Skipped: staging blob no longer exists (already transferred?)",
                object=blob_name
            )
            return

        s3_client = get_s3_client()
        target_bucket = os.environ['TARGET_BUCKET']

        result = transfer_blob_to_s3(
            blob, s3_client, target_bucket, transferred_by='transfer-function'
        )

        if result:
            if result['status'] == 'already_exists':
                log_structured("Already in S3", object=result['object'])
            else:
                log_structured(
                    "Transferred to S3",
                    object=result['object'],
                    gzip_input=result['gzip_input'],
                    input_size=result['input_size'],
                    output_size=result['output_size'],
                    source_container=result['source_container'],
                    target_bucket=f"s3://{result['target_bucket']}"
                )

    except Exception as e:
        log_structured(
            "Error in transfer function",
            severity='ERROR',
            error=str(e),
            object=blob_name
        )
        # Don't raise - no Event Grid retries here; the sweep function retries
        # stale staging blobs instead.


@app.function_name(name="sweep_stale_blobs")
@app.timer_trigger(arg_name="timer", schedule="%SWEEP_SCHEDULE%")
def sweep_stale_blobs(timer: func.TimerRequest):
    """Retry staging blobs older than AGE_THRESHOLD_MINUTES."""
    staging_account = os.environ['STAGING_ACCOUNT']
    staging_container = os.environ['STAGING_CONTAINER']
    target_bucket = os.environ['TARGET_BUCKET']
    age_threshold_minutes = int(os.environ.get('AGE_THRESHOLD_MINUTES', '60'))

    cutoff_time = datetime.now(timezone.utc) - timedelta(minutes=age_threshold_minutes)

    container_client = get_blob_service_client(staging_account).get_container_client(
        staging_container
    )
    s3_client = get_s3_client()

    success_count = 0
    failure_count = 0
    total_files = 0
    stale_files = 0

    # list_blobs paginates automatically, so this stays memory-efficient.
    for props in container_client.list_blobs():
        total_files += 1

        if props.creation_time and props.creation_time < cutoff_time:
            stale_files += 1
            try:
                blob = AzureBlobRef(container_client.get_blob_client(props.name))
            except ResourceNotFoundError:
                continue  # deleted between list and read
            result = transfer_blob_to_s3(
                blob, s3_client, target_bucket, transferred_by='sweep-function'
            )
            if result:
                success_count += 1
            else:
                failure_count += 1

    log_structured(
        "Sweep complete",
        total_files=total_files,
        stale_files=stale_files,
        success=success_count,
        failures=failure_count,
        age_threshold_minutes=age_threshold_minutes
    )
