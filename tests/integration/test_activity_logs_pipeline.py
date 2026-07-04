"""
Activity Logs pipeline tests (L1-L5, A-UNROLL, A-REAL): Event Hub -> batch
function (gzip NDJSON staging blobs) -> transfer function -> S3, plus the
timer sweep recovery path.

Deterministic tests inject synthetic events directly into the Event Hub. The
subscription-scoped diagnostic setting (whole-subscription firehose, unbounded
multi-minute latency) gets one slow opt-in test (A-REAL).
"""
import json
import time

import pytest

from conftest import (
    blob_exists,
    function_logs_hint,
    list_blobs,
    s3_get_decompressed,
    s3_list_keys,
    s3_object_exists,
    set_function_disabled,
    trigger_function,
    unique_marker,
    upload_staging_blob,
    wait_for,
)

NUM_EVENTS = 20
# Event Hub -> batch fn -> staging -> Event Grid -> transfer fn -> S3; no
# fixed batching window, but allow for cold starts and Event Grid latency
ARRIVAL_TIMEOUT = 420


def _extract_seqs(text, marker):
    """Parse NDJSON lines, returning the set of seq values with our marker."""
    seqs = set()
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(record, dict) and record.get("itest_marker") == marker and "seq" in record:
            seqs.add(int(record["seq"]))
    return seqs


@pytest.fixture(scope="module")
def delivered(tf, s3, send_events):
    """Send NUM_EVENTS uniquely-marked events to the Event Hub and wait until
    every one is present in S3. Returns (marker, found_payloads dict)."""
    marker = unique_marker()
    send_events([
        {"records": [{"itest_marker": marker, "seq": i, "msg": f"integration test event {i}"}]}
        for i in range(NUM_EVENTS)
    ])

    found_payloads = {}  # s3 key -> (decoded text, response)

    def all_events_arrived():
        for key in s3_list_keys(s3, tf["al_s3_bucket"], tf["al_s3_prefix"]):
            if key not in found_payloads:
                body, resp = s3_get_decompressed(s3, tf["al_s3_bucket"], key)
                found_payloads[key] = (body.decode(errors="replace"), resp)
        text = "\n".join(t for t, _ in found_payloads.values())
        return _extract_seqs(text, marker) >= set(range(NUM_EVENTS))

    wait_for(
        f"all {NUM_EVENTS} marked events to reach S3. "
        f"{function_logs_hint(tf, 'al_function_app')}",
        all_events_arrived,
        timeout=ARRIVAL_TIMEOUT,
        interval=15,
    )
    return marker, found_payloads


def test_l1_all_events_delivered(delivered):
    """L1: every uniquely-marked event lands in S3 at least once (delivery is
    at-least-once, so duplicates across batch files are legal)."""
    marker, found_payloads = delivered
    text = "\n".join(t for t, _ in found_payloads.values())
    missing = set(range(NUM_EVENTS)) - _extract_seqs(text, marker)
    assert not missing, f"events never reached S3: seqs {sorted(missing)} (marker {marker})"


def test_l2_compression_contract(delivered):
    """L2: transferred objects carry the documented encoding/type/metadata."""
    _, found_payloads = delivered
    assert found_payloads, "no objects to inspect"
    for key, (_, resp) in found_payloads.items():
        assert resp["ContentEncoding"] == "gzip", f"{key}: expected gzip Content-Encoding"
        assert resp["ContentType"] == "application/x-ndjson", f"{key}: unexpected Content-Type"
        assert resp["Metadata"].get("transferred-by") in ("transfer-function", "sweep-function"), \
            f"{key}: missing/unexpected transferred-by metadata"


def test_l3_staging_container_drains(tf, blob_service, delivered):
    """L3: the staging container empties once transfers complete (blobs are
    deleted after a successful S3 upload)."""

    def drained():
        # Ignore fresh blobs (a batch may flush mid-check); anything older than
        # 3 minutes should have transferred and been deleted
        stale = [
            b.name for b in list_blobs(blob_service, tf["al_staging_account"],
                                       tf["al_staging_container"])
            if (time.time() - b.creation_time.timestamp()) > 180
        ]
        return not stale

    wait_for(
        f"staging container {tf['al_staging_container']} to drain. "
        f"{function_logs_hint(tf, 'al_function_app')}",
        drained,
        timeout=300,
        interval=15,
    )


def test_a_unroll_records_envelope(tf, s3, send_events):
    """A-UNROLL: one Event Hub message with a records[] envelope becomes N
    separate NDJSON lines in S3 (the batch function unrolls the envelope that
    Azure diagnostic settings wrap log entries in)."""
    marker = unique_marker()
    count = 5
    send_events([
        {"records": [{"itest_marker": marker, "seq": i, "unroll": True} for i in range(count)]}
    ])

    fetched = {}

    def all_records_unrolled():
        for key in s3_list_keys(s3, tf["al_s3_bucket"], tf["al_s3_prefix"]):
            if key not in fetched:
                body, _ = s3_get_decompressed(s3, tf["al_s3_bucket"], key)
                fetched[key] = body.decode(errors="replace")
        text = "\n".join(fetched.values())
        return _extract_seqs(text, marker) >= set(range(count))

    wait_for(
        f"all {count} records from one enveloped message to reach S3 as separate lines. "
        f"{function_logs_hint(tf, 'al_function_app')}",
        all_records_unrolled,
        timeout=ARRIVAL_TIMEOUT,
        interval=15,
    )

    # Each record must be its own NDJSON line (not the envelope stored whole)
    for text in fetched.values():
        for line in text.splitlines():
            if marker in line:
                record = json.loads(line)
                assert "records" not in record, "envelope was stored whole instead of unrolled"
                assert record["itest_marker"] == marker


def test_l5_sweep_retries_missed_transfer(tf, blob_service, s3, delivered):
    """L5: the timer sweep function transfers staging blobs the
    event-triggered function missed. Simulates a miss by disabling the
    transfer function (Event Grid delivery fails), stranding a blob in
    staging, and invoking the sweep while delivery is still broken. Depends
    on `delivered` so it runs after the happy-path tests."""
    app = tf["al_function_app"]

    set_function_disabled(tf, app, "transfer_staging_blob", True)
    try:
        # The disable propagates lazily (app restart + trigger sync); retry
        # until an uploaded blob actually strands (stays in staging, never
        # reaches S3)
        stranded_key = None
        for attempt in range(5):
            key = f"azure/itest/manual/stranded-{unique_marker()}.json.gz"
            upload_staging_blob(blob_service, tf, key, [{"stranded": True}])
            time.sleep(45)
            in_staging = blob_exists(blob_service, tf["al_staging_account"],
                                     tf["al_staging_container"], key)
            in_s3 = s3_object_exists(s3, tf["al_s3_bucket"], key)
            if in_staging and not in_s3:
                stranded_key = key
                break
            # Disable hasn't bitten yet - the transfer function processed it.
            # Clean up and retry.
            if in_s3:
                s3.delete_object(Bucket=tf["al_s3_bucket"], Key=key)
        assert stranded_key, "could not strand a blob: function disable never took effect"

        # Run the sweep while delivery is still broken, so the re-transfer can
        # only have come from the sweep (fixture age_threshold_minutes = 0, so
        # the blob is immediately stale)
        trigger_function(tf, app, "sweep_stale_blobs")

        wait_for(
            f"sweep function to transfer stranded {stranded_key}. "
            f"{function_logs_hint(tf, 'al_function_app')}",
            lambda: s3_object_exists(s3, tf["al_s3_bucket"], stranded_key),
            timeout=240,
            interval=10,
        )
        resp = s3.head_object(Bucket=tf["al_s3_bucket"], Key=stranded_key)
        assert resp["Metadata"].get("transferred-by") == "sweep-function"

        wait_for(
            "staging copy of the stranded blob to be deleted after transfer",
            lambda: not blob_exists(blob_service, tf["al_staging_account"],
                                    tf["al_staging_container"], stranded_key),
            timeout=120,
        )
    finally:
        set_function_disabled(tf, app, "transfer_staging_blob", False)


@pytest.mark.slow
def test_a_real_diagnostic_setting_path(tf, s3):
    """A-REAL (opt-in, slow): the subscription diagnostic setting -> Event
    Hub hop - the one wiring the synthetic tests bypass (they inject straight
    into the Event Hub). Passes when ANY real exported Activity Log event
    reaches S3. Material is guaranteed: the apply that built this fixture
    generated hundreds of Administrative events minutes earlier, and a new
    setting's export backfills recent events. A record counts as real if it
    carries the export schema's operationName + category (synthetic events and
    canaries don't).

    Deliberately does NOT wait for one specific fresh event: a new setting
    backfills out of order for its first ~30-45 min with no SLA, so "my event
    within N minutes" is a coin flip (observed: two 30-min timeouts while the
    event was recorded in the Activity Log API). Any config error we could
    ship - wrong category, auth rule, or hub - breaks backfilled and fresh
    events alike, so this gate keeps coverage without the flake. Export pump
    spin-up runs ~13-20 min; the budget covers it. run.sh deselects; include
    with `./run.sh --include-slow-tests`."""
    checked = set()

    def real_event_arrived():
        for key in s3_list_keys(s3, tf["al_s3_bucket"], tf["al_s3_prefix"]):
            if key in checked:
                continue
            body, _ = s3_get_decompressed(s3, tf["al_s3_bucket"], key)
            checked.add(key)
            for line in body.decode(errors="replace").splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(record, dict) and "operationName" in record \
                        and "category" in record:
                    return f"{record.get('operationName')} (in {key})"
        return None

    found = wait_for(
        "a real exported Activity Log event (operationName + category) to reach "
        f"S3 via the diagnostic setting. {function_logs_hint(tf, 'al_function_app')}",
        real_event_arrived,
        timeout=1800,
        interval=30,
    )
    assert found
