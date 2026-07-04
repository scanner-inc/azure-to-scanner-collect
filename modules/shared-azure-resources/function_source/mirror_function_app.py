"""
Mirror function app: copies blobs from a monitored (customer-owned) Azure
Blob Storage container to S3.

Receives BlobCreated events via an Event Grid subscription on the source
storage account, applies key path filtering (KEY_PREFIXES /
KEY_INCLUDE_REGEX / KEY_EXCLUDE_REGEX), and copies matching blobs to S3.
Never deletes from the source container.

Reliability contract: returns normally (acking the event) for anything
retrying cannot fix (filtered keys, deleted blobs, malformed events) and
raises on transient failures so Event Grid redelivers with backoff; after
max delivery attempts the event lands in the dead-letter container, where a
monitoring alert fires.

This file is deployed as function_app.py in the mirror function app.
"""
import os

import azure.functions as func
from azure.core.exceptions import ResourceNotFoundError

from shared import (
    AzureBlobRef,
    build_dest_key,
    get_blob_service_client,
    get_s3_client,
    key_passes_filter,
    log_structured,
    parse_blob_created_subject,
    transfer_blob_to_s3,
)

app = func.FunctionApp()


class TransientTransferError(Exception):
    """Raised so Event Grid redelivers the event with backoff."""


@app.function_name(name="mirror_blob")
@app.event_grid_trigger(arg_name="event")
def mirror_blob(event: func.EventGridEvent):
    """Mirror a newly-created source blob to S3 (leaving the source in place)."""

    # The subscription only sends BlobCreated, but be defensive
    if event.event_type and event.event_type != 'Microsoft.Storage.BlobCreated':
        log_structured("Ignored: unexpected event type", eventType=event.event_type)
        return

    container_name, blob_name = parse_blob_created_subject(event.subject)
    if not blob_name:
        log_structured(
            "Ignored: event subject missing container/blob identifiers",
            severity='ERROR',
            subject=event.subject
        )
        return

    # Only process blobs from the monitored source container
    expected_container = os.environ.get('SOURCE_CONTAINER')
    if container_name != expected_container:
        log_structured(
            "Rejected: unexpected container",
            severity='WARNING',
            container=container_name,
            expected=expected_container,
            object=blob_name
        )
        return

    # Prefix filtering also happens server-side via the subscription's
    # subject_begins_with; the regexes only apply here.
    if not key_passes_filter(blob_name):
        log_structured(
            "Skipped: blob name filtered out",
            object=blob_name,
            container=container_name
        )
        return

    try:
        source_account = os.environ['SOURCE_ACCOUNT']
        blob_client = get_blob_service_client(source_account).get_blob_client(
            container=container_name, blob=blob_name
        )
        try:
            blob = AzureBlobRef(blob_client)
        except ResourceNotFoundError:
            log_structured(
                "Skipped: blob no longer exists in source container",
                object=blob_name,
                container=container_name
            )
            return  # deleted before we got to it - retrying cannot fix

        s3_client = get_s3_client()
        target_bucket = os.environ['TARGET_BUCKET']

        # Copy to S3 (do not delete the source blob)
        result = transfer_blob_to_s3(
            blob,
            s3_client,
            target_bucket,
            transferred_by='mirror-function',
            dest_key=build_dest_key(blob_name),
            delete_source=False
        )

        if result is None:
            # transfer_blob_to_s3 logged the underlying error
            raise TransientTransferError(
                f"Transfer to S3 failed for {blob_name} - event will be retried"
            )

        if result['status'] == 'already_exists':
            log_structured("Already in S3", object=result['object'])
        else:
            log_structured(
                "Mirrored to S3",
                object=result['object'],
                gzip_input=result['gzip_input'],
                input_size=result['input_size'],
                output_size=result['output_size'],
                source_container=result['source_container'],
                target_bucket=f"s3://{result['target_bucket']}"
            )

    except TransientTransferError:
        raise
    except Exception as e:
        log_structured(
            "Error in mirror function - event will be retried",
            severity='ERROR',
            error=str(e),
            object=blob_name
        )
        raise
