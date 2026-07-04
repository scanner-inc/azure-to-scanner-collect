"""
Mirror pipeline tests: blob creation -> Event Grid -> key filtering -> copy
to S3, with the source blob left untouched.
"""
import gzip as gz
import time

import pytest

from conftest import (
    blob_exists,
    function_logs_hint,
    s3_get_decompressed,
    s3_object_exists,
    set_function_disabled,
    unique_marker,
    upload_blob,
    wait_for,
)

ARRIVAL_TIMEOUT = 180       # mirror path is event-triggered, no batching
NEGATIVE_GRACE_SECONDS = 45 # extra wait after the positive control lands


def _s3_key(tf, blob_name):
    return f"{tf['mirror_s3_key_prefix']}/{blob_name}"


def _upload(blob_service, tf, name, data, **kwargs):
    upload_blob(blob_service, tf["mirror_source_account"], tf["mirror_source_container"],
                name, data, **kwargs)


def test_m1_m2_happy_path_and_source_preserved(tf, blob_service, s3):
    """M1: matching blob is copied to S3 under the key prefix, content
    intact. M2: the source blob is never deleted."""
    marker = unique_marker()
    blob_name = f"logs/{marker}/a.json"
    original = ('{"event": "login", "marker": "%s"}\n' % marker).encode() * 50

    _upload(blob_service, tf, blob_name, original)

    wait_for(
        f"{blob_name} to be mirrored to S3. {function_logs_hint(tf, 'mirror_function_app')}",
        lambda: s3_object_exists(s3, tf["mirror_s3_bucket"], _s3_key(tf, blob_name)),
        timeout=ARRIVAL_TIMEOUT,
    )

    # M1: content round-trips; plain files are gzipped on the fly
    body, resp = s3_get_decompressed(s3, tf["mirror_s3_bucket"], _s3_key(tf, blob_name))
    assert body == original, "mirrored content differs from source"
    assert resp["ContentEncoding"] == "gzip", "plain files should be gzip-encoded in S3"
    assert resp["Metadata"].get("transferred-by") == "mirror-function"
    assert resp["Metadata"].get("source-account") == tf["mirror_source_account"]
    assert resp["Metadata"].get("source-container") == tf["mirror_source_container"]

    # M2: source blob still exists
    assert blob_exists(blob_service, tf["mirror_source_account"],
                       tf["mirror_source_container"], blob_name), \
        "mirror pipeline must NEVER delete source blobs"


def test_m3_m4_m5_filters_exclude_non_matching_keys(tf, blob_service, s3):
    """M3: wrong prefix is not copied. M4: exclude regex is honored.
    M5: include regex is honored. A positive control bounds the wait."""
    marker = unique_marker()
    control_key = f"logs/{marker}/control.json"
    negatives = [
        f"other/{marker}/b.json",   # M3: outside key_prefixes ["logs/"]
        f"logs/{marker}/c.tmp",     # M4: matches key_exclude_regex \.tmp$
        f"logs/{marker}/d.csv",     # M5: fails key_include_regex \.(json|jsonl)(\.gz)?$
    ]

    for key in negatives:
        _upload(blob_service, tf, key, b'{"should": "never copy"}')
    _upload(blob_service, tf, control_key, b'{"control": true}')

    wait_for(
        f"positive control {control_key} to reach S3. {function_logs_hint(tf, 'mirror_function_app')}",
        lambda: s3_object_exists(s3, tf["mirror_s3_bucket"], _s3_key(tf, control_key)),
        timeout=ARRIVAL_TIMEOUT,
    )

    # The control (uploaded last) arrived; give stragglers a grace period,
    # then assert the filtered keys never made it.
    time.sleep(NEGATIVE_GRACE_SECONDS)
    for key in negatives:
        assert not s3_object_exists(s3, tf["mirror_s3_bucket"], _s3_key(tf, key)), \
            f"filtered-out key {key} was wrongly copied to S3"


def test_m7_pre_gzipped_file_copied_byte_for_byte(tf, blob_service, s3):
    """M7: a .gz file is copied verbatim - no re-compression, no
    Content-Encoding header (the extension already conveys it).
    Uses .json.gz so the include regex passes."""
    marker = unique_marker()
    blob_name = f"logs/{marker}/e.json.gz"
    inner = ('{"marker": "%s"}\n' % marker).encode() * 100
    original_gz = gz.compress(inner)

    _upload(blob_service, tf, blob_name, original_gz)

    wait_for(
        f"{blob_name} to be mirrored to S3. {function_logs_hint(tf, 'mirror_function_app')}",
        lambda: s3_object_exists(s3, tf["mirror_s3_bucket"], _s3_key(tf, blob_name)),
        timeout=ARRIVAL_TIMEOUT,
    )

    resp = s3.get_object(Bucket=tf["mirror_s3_bucket"], Key=_s3_key(tf, blob_name))
    body = resp["Body"].read()
    assert body == original_gz, ".gz files must be copied byte-for-byte"
    assert resp.get("ContentEncoding") is None, ".gz passthrough must not set Content-Encoding"
    assert gz.decompress(body) == inner


def test_m8_content_encoding_gzip_preserved(tf, blob_service, s3):
    """M8: a blob stored with Content-Encoding: gzip metadata lands in S3
    with the encoding preserved and content intact. (The Azure SDK
    auto-decompresses such downloads, so the pipeline re-compresses; the
    decompressed content must round-trip exactly.)"""
    marker = unique_marker()
    blob_name = f"logs/{marker}/enc.json"
    inner = ('{"m8": true, "marker": "%s"}\n' % marker).encode() * 100
    compressed = gz.compress(inner)

    _upload(blob_service, tf, blob_name, compressed,
            content_type="application/json", content_encoding="gzip")

    wait_for(
        f"{blob_name} to be mirrored to S3. {function_logs_hint(tf, 'mirror_function_app')}",
        lambda: s3_object_exists(s3, tf["mirror_s3_bucket"], _s3_key(tf, blob_name)),
        timeout=ARRIVAL_TIMEOUT,
    )

    body, resp = s3_get_decompressed(s3, tf["mirror_s3_bucket"], _s3_key(tf, blob_name))
    assert resp["ContentEncoding"] == "gzip"
    assert body == inner, "decompressed S3 content differs from original"
    assert resp["Metadata"].get("original-encoding") == "gzip"


@pytest.mark.slow
def test_m12_redelivery_recovers_from_outage(tf, blob_service, s3):
    """M12 (opt-in, slow): Event Grid redelivery alone recovers from a
    delivery outage. Break delivery by disabling the mirror function, upload a
    blob, confirm it strands, re-enable, and verify Event Grid's scheduled
    retry lands the blob with no other mechanism involved.

    Slow because Event Grid's retry schedule is fixed and spaced (10s, 30s,
    1m, 5m, 10m, ...) - by the time the outage is confirmed and delivery
    restored, the next retry is typically 5-10 min out, with no retry-now
    knob. Include with `./run.sh --include-slow-tests`."""
    app = tf["mirror_function_app"]

    set_function_disabled(tf, app, "mirror_blob", True)
    restored = False
    try:
        # The disable propagates lazily; retry until an upload actually
        # strands (its delivery is failing)
        blocked_key = None
        for attempt in range(5):
            key = f"logs/{unique_marker()}/redelivery.json"
            _upload(blob_service, tf, key, b'{"redelivery": true}\n')
            time.sleep(45)
            if not s3_object_exists(s3, tf["mirror_s3_bucket"], _s3_key(tf, key)):
                blocked_key = key
                break
        assert blocked_key, "could not block delivery: function disable never took effect"

        # Restore delivery and let Event Grid's retry backoff redeliver
        set_function_disabled(tf, app, "mirror_blob", False)
        restored = True

        wait_for(
            f"Event Grid redelivery to land {blocked_key} after the outage. "
            f"{function_logs_hint(tf, 'mirror_function_app')}",
            lambda: s3_object_exists(s3, tf["mirror_s3_bucket"], _s3_key(tf, blocked_key)),
            timeout=900,  # retry gaps grow to 10 min at this point in the schedule
            interval=15,
        )
        resp = s3.head_object(Bucket=tf["mirror_s3_bucket"], Key=_s3_key(tf, blocked_key))
        assert resp["Metadata"].get("transferred-by") == "mirror-function"

        # Source untouched, as always
        assert blob_exists(blob_service, tf["mirror_source_account"],
                           tf["mirror_source_container"], blocked_key)
    finally:
        if not restored:
            set_function_disabled(tf, app, "mirror_blob", False)
