"""
Existing-bucket mirror pipeline test (M9): an unfiltered mirror instance
delivering into a pre-existing S3 bucket - exercises existing_s3_bucket_name
and multi-instance coexistence (the fixture's second Event Grid system topic).
"""
import time

from conftest import (
    blob_exists,
    function_logs_hint,
    s3_get_decompressed,
    s3_object_exists,
    unique_marker,
    upload_blob,
    wait_for,
)


def test_m9_unfiltered_mirror_to_existing_s3(tf, blob_service, s3):
    """M9: blobs created in the second source account are mirrored into an
    S3 bucket the module treats as pre-existing."""
    marker = unique_marker()
    account = tf["mirror_ex_source_account"]
    container = tf["mirror_ex_source_container"]
    s3_bucket = tf["mirror_ex_s3_bucket"]
    prefix = tf["mirror_ex_s3_key_prefix"]

    # This subscription hasn't carried an event yet (the session canary
    # settles the primary mirror's, not this one), so re-upload until
    # delivered before asserting content.
    deadline = time.monotonic() + 420
    delivered_key = None
    attempt = 0
    original = ('{"m9": true, "marker": "%s"}\n' % marker).encode() * 50
    while time.monotonic() < deadline and delivered_key is None:
        attempt += 1
        # No filters on this instance: any key mirrors
        key = f"raw/{marker}/existing-{attempt}.json"
        upload_blob(blob_service, account, container, key, original)
        try:
            wait_for(
                f"{key} to reach existing S3 bucket",
                lambda k=key: s3_object_exists(s3, s3_bucket, f"{prefix}/{k}"),
                timeout=75,
            )
            delivered_key = key
        except AssertionError:
            continue

    assert delivered_key, (
        "existing-bucket mirror never delivered a blob within 7 minutes. "
        f"{function_logs_hint(tf, 'mirror_ex_function_app')}"
    )

    # Content round-trips; source untouched
    body, resp = s3_get_decompressed(s3, s3_bucket, f"{prefix}/{delivered_key}")
    assert body == original
    assert resp["Metadata"].get("transferred-by") == "mirror-function"
    assert blob_exists(blob_service, account, container, delivered_key), \
        "source blob must never be deleted"

    # The module must not manage lifecycle on an existing bucket
    try:
        s3.get_bucket_lifecycle_configuration(Bucket=s3_bucket)
        raise AssertionError("existing S3 bucket unexpectedly has a lifecycle configuration")
    except s3.exceptions.ClientError as e:
        assert e.response["Error"]["Code"] == "NoSuchLifecycleConfiguration"
