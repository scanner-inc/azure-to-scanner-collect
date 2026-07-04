"""
Dead-letter test (DL1): events that exhaust delivery attempts land in the
dead-letter container.

Runs against the mir_ex instance, whose subscription has low dead-letter
knobs (max_delivery_attempts=3, event_ttl_minutes=5) so this test is bounded
- production defaults retry up to 24h. Event Grid also batches dead-letter
writes (~5 min flush delay), hence the generous timeout.

Collected before test_mirror_existing.py (alphabetical). It disables the
mir_ex mirror function and re-enables it in finally; M9's
re-upload-until-delivered loop tolerates the recovery window left behind.
"""
import time

import pytest

from conftest import (
    function_logs_hint,
    list_blobs,
    set_function_disabled,
    unique_marker,
    upload_blob,
    wait_for,
)


@pytest.mark.slow
def test_dl1_exhausted_deliveries_dead_letter(tf, blob_service, s3):
    """DL1 (opt-in, slow): with delivery broken, an event dead-letters to the
    DLQ container within the subscription's bounded retry budget.

    Slow because even with the fixture's low knobs (3 attempts / 5 min TTL),
    Event Grid batches dead-letter writes and flushes them roughly every 5
    minutes, so the blob can take ~10 min to appear. Include with
    `./run.sh --include-slow-tests`."""
    app = tf["mirror_ex_function_app"]
    marker = unique_marker()

    def dead_letter_blobs_with_marker():
        # Dead-letter blobs are JSON arrays of the failed events; the event
        # subject contains the source blob path (which embeds our marker)
        for props in list_blobs(blob_service, tf["mirror_ex_dlq_account"],
                                tf["mirror_ex_dlq_container"]):
            client = blob_service(tf["mirror_ex_dlq_account"]).get_blob_client(
                container=tf["mirror_ex_dlq_container"], blob=props.name
            )
            content = client.download_blob().readall().decode(errors="replace")
            if marker in content:
                return props.name
        return None

    set_function_disabled(tf, app, "mirror_blob", True)
    try:
        # Upload poison blobs spaced over time so at least one event is
        # created after the disable has fully propagated.
        for i in range(3):
            upload_blob(
                blob_service, tf["mirror_ex_source_account"], tf["mirror_ex_source_container"],
                f"dlq/{marker}/poison-{i}.json", b'{"poison": true}\n',
            )
            time.sleep(30)

        # TTL 5 min + documented ~5 min dead-letter flush delay + slack
        wait_for(
            f"a dead-lettered event for marker {marker} to appear in the DLQ container. "
            f"{function_logs_hint(tf, 'mirror_ex_function_app')}",
            dead_letter_blobs_with_marker,
            timeout=900,
            interval=20,
        )
    finally:
        set_function_disabled(tf, app, "mirror_blob", False)
