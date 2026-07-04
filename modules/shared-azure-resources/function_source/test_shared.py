"""
Unit tests for shared.py utilities.
Run with: python -m pytest test_shared.py -v

No cloud credentials required: shared.py initializes all clients lazily, and
these tests only exercise the pure helpers (compression, key filtering,
records unrolling, NDJSON batching, naming, subject parsing).
"""
import gzip
import io
import json
import os
from datetime import datetime, timezone

import pytest

from shared import (
    BlobStreamReader,
    GzipStreamWrapper,
    MODE_COMPRESS,
    MODE_RAW_GZIP,
    MODE_VERBATIM,
    build_dest_key,
    build_staging_blob_name,
    content_type_for,
    decide_transfer_mode,
    gzip_bytes,
    key_passes_filter,
    parse_blob_created_subject,
    records_to_ndjson_batches,
    unroll_records,
)


# ============================================================================
# GzipStreamWrapper (ported from the GCP suite)
# ============================================================================

def test_gzip_stream_wrapper_basic():
    """Test that GzipStreamWrapper produces valid gzip output"""
    original_data = b"Hello, World! " * 100

    source = io.BytesIO(original_data)
    wrapper = GzipStreamWrapper(source)
    compressed_data = wrapper.read()

    # Verify it's actually compressed (should be smaller for repetitive data)
    assert len(compressed_data) < len(original_data), "Data should be compressed"

    # Verify it's valid gzip by decompressing
    decompressed = gzip.decompress(compressed_data)
    assert decompressed == original_data, "Decompressed data should match original"


def test_gzip_stream_wrapper_chunked_reading():
    """Test that reading in chunks produces the same result"""
    original_data = b"The quick brown fox jumps over the lazy dog. " * 50

    # Compress by reading all at once
    wrapper1 = GzipStreamWrapper(io.BytesIO(original_data))
    compressed_all = wrapper1.read()

    # Compress by reading in chunks
    wrapper2 = GzipStreamWrapper(io.BytesIO(original_data))
    compressed_chunks = b''
    while True:
        chunk = wrapper2.read(1024)  # Read 1KB at a time
        if not chunk:
            break
        compressed_chunks += chunk

    assert gzip.decompress(compressed_all) == original_data
    assert gzip.decompress(compressed_chunks) == original_data


def test_gzip_stream_wrapper_empty_input():
    """Test handling of empty input"""
    wrapper = GzipStreamWrapper(io.BytesIO(b""))
    compressed = wrapper.read()

    # Even empty input should produce valid gzip (just header/trailer)
    assert gzip.decompress(compressed) == b""
    assert len(compressed) > 0, "Empty gzip still has header/trailer"


def test_gzip_stream_wrapper_large_data():
    """Test with larger data to ensure streaming works"""
    original_data = b"x" * (1024 * 1024)

    wrapper = GzipStreamWrapper(io.BytesIO(original_data), chunk_size=8192)
    compressed = wrapper.read()

    assert len(compressed) < len(original_data) * 0.01, "Repetitive data should compress >99%"
    assert gzip.decompress(compressed) == original_data


def test_gzip_compatibility_with_gunzip():
    """Test that output is compatible with standard gzip tools"""
    original_data = b"This is a test of gzip compatibility.\n" * 10

    wrapper = GzipStreamWrapper(io.BytesIO(original_data))
    compressed = wrapper.read()

    decompressed = gzip.GzipFile(fileobj=io.BytesIO(compressed)).read()
    assert decompressed == original_data

    with gzip.open(io.BytesIO(compressed), 'rb') as f:
        assert f.read() == original_data


def test_gzip_stream_wrapper_binary_data():
    """Test with binary data (not just text)"""
    original_data = bytes(range(256)) * 100

    wrapper = GzipStreamWrapper(io.BytesIO(original_data))
    compressed = wrapper.read()

    assert gzip.decompress(compressed) == original_data


def test_gzip_stream_wrapper_multiple_reads():
    """Test that wrapper can handle multiple read() calls correctly"""
    original_data = b"A" * 1000

    wrapper = GzipStreamWrapper(io.BytesIO(original_data), chunk_size=100)

    chunks = []
    for _ in range(5):
        chunk = wrapper.read(50)
        if chunk:
            chunks.append(chunk)
    rest = wrapper.read()
    if rest:
        chunks.append(rest)

    compressed = b''.join(chunks)
    assert gzip.decompress(compressed) == original_data


# ============================================================================
# BlobStreamReader error propagation
# ============================================================================

class _FailingDownloader:
    """StorageStreamDownloader stand-in whose chunk iterator dies mid-stream."""
    def __init__(self, good_chunks):
        self._good_chunks = good_chunks

    def chunks(self):
        yield from self._good_chunks
        raise IOError("connection reset by peer")


def test_blob_stream_reader_propagates_midstream_errors():
    """A transport error must RAISE, never read as EOF.

    boto3 treats an empty read as end-of-stream, so swallowing the error would
    upload a silently truncated object and count it as success (the source
    blob would then be deleted on the staging path)."""
    reader = BlobStreamReader(_FailingDownloader([b"abcd"]))
    assert reader.read(4) == b"abcd"
    with pytest.raises(IOError):
        reader.read(4)


def test_blob_stream_reader_propagates_errors_on_read_all():
    reader = BlobStreamReader(_FailingDownloader([b"abcd"]))
    with pytest.raises(IOError):
        reader.read()


def test_blob_stream_reader_happy_path_unchanged():
    class Downloader:
        def chunks(self):
            return iter([b"hello ", b"world"])

    reader = BlobStreamReader(Downloader())
    assert reader.read(5) == b"hello"
    assert reader.read() == b" world"
    assert reader.bytes_written == 11


# ============================================================================
# key_passes_filter (ported from the GCP suite)
# ============================================================================

def test_key_passes_filter_no_filters():
    """With no filters configured, every key passes"""
    assert key_passes_filter("any/key.json", prefixes=[], include_regex="", exclude_regex="")
    assert key_passes_filter("", prefixes=[], include_regex="", exclude_regex="")


def test_key_passes_filter_prefixes():
    """Prefix filter: key must start with one of the prefixes"""
    prefixes = ["logs/", "exports/"]
    assert key_passes_filter("logs/2026/07/01/file.json", prefixes=prefixes, include_regex="", exclude_regex="")
    assert key_passes_filter("exports/dump.csv", prefixes=prefixes, include_regex="", exclude_regex="")
    assert not key_passes_filter("other/file.json", prefixes=prefixes, include_regex="", exclude_regex="")
    assert not key_passes_filter("mylogs/file.json", prefixes=prefixes, include_regex="", exclude_regex="")


def test_key_passes_filter_include_regex():
    """Include regex: key must match"""
    assert key_passes_filter("logs/file.json.gz", prefixes=[], include_regex=r"\.json(\.gz)?$", exclude_regex="")
    assert key_passes_filter("logs/file.json", prefixes=[], include_regex=r"\.json(\.gz)?$", exclude_regex="")
    assert not key_passes_filter("logs/file.txt", prefixes=[], include_regex=r"\.json(\.gz)?$", exclude_regex="")


def test_key_passes_filter_exclude_regex():
    """Exclude regex: key must not match"""
    assert not key_passes_filter("logs/file.tmp", prefixes=[], include_regex="", exclude_regex=r"\.tmp$")
    assert key_passes_filter("logs/file.json", prefixes=[], include_regex="", exclude_regex=r"\.tmp$")


def test_key_passes_filter_combined():
    """All configured filters must pass"""
    kwargs = dict(prefixes=["logs/"], include_regex=r"\.json$", exclude_regex=r"/_temporary/")
    assert key_passes_filter("logs/2026/file.json", **kwargs)
    assert not key_passes_filter("exports/2026/file.json", **kwargs)  # wrong prefix
    assert not key_passes_filter("logs/2026/file.csv", **kwargs)      # fails include
    assert not key_passes_filter("logs/_temporary/file.json", **kwargs)  # matches exclude


def test_key_passes_filter_env_defaults(monkeypatch):
    """Filters default to the KEY_* environment variables"""
    monkeypatch.setenv('KEY_PREFIXES', 'logs/,exports/')
    monkeypatch.setenv('KEY_INCLUDE_REGEX', r'\.json$')
    monkeypatch.setenv('KEY_EXCLUDE_REGEX', r'\.tmp')
    assert key_passes_filter("logs/a.json")
    assert not key_passes_filter("other/a.json")
    assert not key_passes_filter("logs/a.csv")


# ============================================================================
# unroll_records (Azure diagnostic-settings envelope)
# ============================================================================

def test_unroll_records_envelope():
    """N records in the envelope become N individual records"""
    records = [{"operationName": f"op{i}", "seq": i} for i in range(5)]
    body = json.dumps({"records": records})
    assert unroll_records(body) == records


def test_unroll_records_bytes_input():
    """Event Hub bodies arrive as bytes"""
    body = json.dumps({"records": [{"a": 1}]}).encode('utf-8')
    assert unroll_records(body) == [{"a": 1}]


def test_unroll_records_no_envelope():
    """A message without a records array is kept whole"""
    body = {"operationName": "standalone", "level": "Informational"}
    assert unroll_records(json.dumps(body)) == [body]


def test_unroll_records_empty_records():
    """An empty records array yields no records"""
    assert unroll_records('{"records": []}') == []


def test_unroll_records_malformed():
    """Malformed inputs are skipped, not raised"""
    assert unroll_records("not json {") == []
    assert unroll_records(b"\xff\xfe invalid utf8 \xff") == []
    assert unroll_records('[1, 2, 3]') == []
    assert unroll_records('"just a string"') == []


def test_unroll_records_non_dict_entries_dropped():
    """Non-object entries inside records are dropped"""
    body = json.dumps({"records": [{"a": 1}, "junk", 42, {"b": 2}]})
    assert unroll_records(body) == [{"a": 1}, {"b": 2}]


# ============================================================================
# records_to_ndjson_batches
# ============================================================================

def test_ndjson_batches_basic():
    """Records serialize to one NDJSON batch, one record per line"""
    records = [{"seq": i} for i in range(10)]
    batches = records_to_ndjson_batches(records)
    assert len(batches) == 1

    lines = batches[0].decode('utf-8').splitlines()
    assert [json.loads(line) for line in lines] == records
    assert batches[0].endswith(b'\n'), "Each line (including the last) ends with newline"


def test_ndjson_batches_split_on_size():
    """Batches split when they exceed the size cap; order is preserved"""
    records = [{"seq": i, "pad": "x" * 100} for i in range(50)]
    line_size = len(json.dumps(records[0], separators=(',', ':'))) + 1
    cap = line_size * 10 + 5  # ~10 records per batch

    batches = records_to_ndjson_batches(records, max_batch_bytes=cap)
    assert len(batches) > 1
    assert all(len(b) <= cap for b in batches)

    # Reassembled stream preserves every record in order
    all_lines = b''.join(batches).decode('utf-8').splitlines()
    assert [json.loads(line)["seq"] for line in all_lines] == list(range(50))


def test_ndjson_batches_oversized_record_skipped():
    """A single record larger than the cap is skipped, not sent"""
    records = [{"a": 1}, {"huge": "x" * 1000}, {"b": 2}]
    batches = records_to_ndjson_batches(records, max_batch_bytes=200)
    all_lines = b''.join(batches).decode('utf-8').splitlines()
    assert [json.loads(line) for line in all_lines] == [{"a": 1}, {"b": 2}]


def test_ndjson_batches_empty():
    assert records_to_ndjson_batches([]) == []


def test_ndjson_batches_gzip_roundtrip():
    """A gzipped batch is a valid gzip NDJSON document (the staging blob body)"""
    records = [{"seq": i} for i in range(3)]
    batch = records_to_ndjson_batches(records)[0]
    compressed = gzip_bytes(batch)
    assert gzip.decompress(compressed) == batch


# ============================================================================
# decide_transfer_mode / content_type_for (the compression contract)
# ============================================================================

def test_transfer_mode_stored_gzip():
    """Content-Encoding gzip wins regardless of extension"""
    assert decide_transfer_mode("logs/a.json", "gzip") == MODE_RAW_GZIP
    assert decide_transfer_mode("logs/a.json.gz", "gzip") == MODE_RAW_GZIP


def test_transfer_mode_already_compressed_extension():
    """Compressed extensions copy verbatim (no re-compression, no header)"""
    for ext in ('.gz', '.gzip', '.zip', '.bz2', '.zst', '.snappy', '.parquet'):
        assert decide_transfer_mode(f"logs/file{ext}", None) == MODE_VERBATIM
    assert decide_transfer_mode("logs/FILE.GZ", None) == MODE_VERBATIM  # case-insensitive


def test_transfer_mode_plain():
    """Everything else is gzip-compressed on the fly"""
    assert decide_transfer_mode("logs/a.json", None) == MODE_COMPRESS
    assert decide_transfer_mode("logs/a.txt", "") == MODE_COMPRESS
    assert decide_transfer_mode("logs/a.csv", "identity") == MODE_COMPRESS


def test_content_type_ndjson():
    assert content_type_for("a/b.jsonl", None) == 'application/x-ndjson'
    assert content_type_for("a/b.ndjson", None) == 'application/x-ndjson'
    assert content_type_for("a/b.json.gz", None) == 'application/octet-stream'
    assert content_type_for("a/b.jsonl.gz", None) == 'application/x-ndjson'
    assert content_type_for("a/b.csv", "text/csv") == 'text/csv'
    assert content_type_for("a/b.bin", None) == 'application/octet-stream'


def test_content_type_case_insensitive():
    """Extension matching ignores case, like decide_transfer_mode"""
    assert content_type_for("a/B.JSONL", None) == 'application/x-ndjson'
    assert content_type_for("a/B.NDJSON", None) == 'application/x-ndjson'
    assert content_type_for("a/B.JSONL.GZ", None) == 'application/x-ndjson'
    assert content_type_for("a/B.Jsonl.Gz", None) == 'application/x-ndjson'
    assert content_type_for("a/B.CSV", "text/csv") == 'text/csv'


# ============================================================================
# build_staging_blob_name
# ============================================================================

def test_staging_blob_name_scheme():
    """Names match the GCP scheme: {prefix}/YYYY/MM/DD/hh/mm_ssZ_<id>.json.gz"""
    now = datetime(2026, 7, 3, 22, 15, 30, tzinfo=timezone.utc)
    name = build_staging_blob_name("azure/activity", now, unique_id="abc123")
    assert name == "azure/activity/2026/07/03/22/15_30Z_abc123.json.gz"


def test_staging_blob_name_no_prefix():
    now = datetime(2026, 1, 2, 3, 4, 5, tzinfo=timezone.utc)
    name = build_staging_blob_name("", now, unique_id="xyz")
    assert name == "2026/01/02/03/04_05Z_xyz.json.gz"


def test_staging_blob_name_strips_slashes():
    now = datetime(2026, 1, 2, 3, 4, 5, tzinfo=timezone.utc)
    name = build_staging_blob_name("/azure/activity/", now, unique_id="xyz")
    assert name.startswith("azure/activity/2026/")


def test_staging_blob_name_unique():
    now = datetime(2026, 1, 2, 3, 4, 5, tzinfo=timezone.utc)
    assert build_staging_blob_name("p", now) != build_staging_blob_name("p", now)


# ============================================================================
# parse_blob_created_subject
# ============================================================================

def test_parse_subject_basic():
    subject = "/blobServices/default/containers/raw-logs/blobs/logs/2026/07/03/file.json"
    container, blob = parse_blob_created_subject(subject)
    assert container == "raw-logs"
    assert blob == "logs/2026/07/03/file.json"


def test_parse_subject_single_segment_blob():
    container, blob = parse_blob_created_subject(
        "/blobServices/default/containers/c1/blobs/file.txt"
    )
    assert (container, blob) == ("c1", "file.txt")


def test_parse_subject_invalid():
    assert parse_blob_created_subject("") == (None, None)
    assert parse_blob_created_subject(None) == (None, None)
    assert parse_blob_created_subject("/some/other/subject") == (None, None)
    assert parse_blob_created_subject("/blobServices/default/containers/c1") == (None, None)


# ============================================================================
# build_dest_key
# ============================================================================

def test_build_dest_key(monkeypatch):
    monkeypatch.setenv('S3_KEY_PREFIX', 'azure/mirror')
    assert build_dest_key("logs/a.json") == "azure/mirror/logs/a.json"

    monkeypatch.setenv('S3_KEY_PREFIX', '/azure/mirror/')
    assert build_dest_key("logs/a.json") == "azure/mirror/logs/a.json", "no double slashes"

    monkeypatch.setenv('S3_KEY_PREFIX', '')
    assert build_dest_key("logs/a.json") == "logs/a.json"


if __name__ == "__main__":
    import sys
    sys.exit(pytest.main([__file__, "-v"]))
