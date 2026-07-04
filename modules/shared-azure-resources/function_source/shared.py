"""
Shared utilities for Azure Blob Storage to S3 transfer functions
"""
import io
import json
import os
import re
import uuid
import zlib

import boto3

# Azure SDK imports are deferred inside functions so this module can be
# imported (and the pure helpers unit-tested) without Azure credentials.

# Lazily-initialized, cached at module scope.
_credential = None
_blob_service_clients = {}


def log_structured(message, severity='INFO', **kwargs):
    """Emit a structured JSON log line (picked up by App Insights / log stream)."""
    entry = {
        'message': message,
        'severity': severity,
    }
    entry.update(kwargs)
    print(json.dumps(entry))


class GzipStreamWrapper:
    """File-like adapter that gzip-compresses a source stream on the fly."""
    def __init__(self, fileobj, chunk_size=65536):
        self.fileobj = fileobj
        self.chunk_size = chunk_size
        # wbits=16+MAX_WBITS: max window plus a gzip header/trailer.
        self.compressor = zlib.compressobj(wbits=16 + zlib.MAX_WBITS)
        self.buffer = b''
        self.finished = False
        self.bytes_written = 0  # compressed bytes output

    def read(self, size=-1):
        while len(self.buffer) < size or size == -1:
            if self.finished:
                break

            chunk = self.fileobj.read(self.chunk_size)

            if not chunk:
                # Source exhausted; finalize compression.
                self.buffer += self.compressor.flush()
                self.finished = True
                break

            self.buffer += self.compressor.compress(chunk)

            if size != -1 and len(self.buffer) >= size:
                break

        if size == -1:
            result = self.buffer
            self.buffer = b''
        else:
            result = self.buffer[:size]
            self.buffer = self.buffer[size:]

        self.bytes_written += len(result)
        return result


def get_credential():
    """Azure credential for this function app's managed identity.

    DefaultAzureCredential also works locally (az login). AZURE_CLIENT_ID
    selects the user-assigned managed identity when running in Azure.
    """
    global _credential
    if _credential is None:
        from azure.identity import DefaultAzureCredential
        _credential = DefaultAzureCredential(
            managed_identity_client_id=os.environ.get('AZURE_CLIENT_ID')
        )
    return _credential


def get_blob_service_client(account_name):
    """Cached BlobServiceClient for a storage account."""
    if account_name not in _blob_service_clients:
        from azure.storage.blob import BlobServiceClient
        _blob_service_clients[account_name] = BlobServiceClient(
            account_url=f"https://{account_name}.blob.core.windows.net",
            credential=get_credential(),
        )
    return _blob_service_clients[account_name]


def get_entra_id_token(audience):
    """Entra ID access token (JWT) for the given audience.

    Entra ID only mints tokens for audiences that resolve to a service
    principal in the tenant. The AWS IAM role's trust policy pins this
    audience (aud claim) plus the managed identity's principal id (sub claim).
    """
    try:
        return get_credential().get_token(f"{audience}/.default").token
    except Exception as e:
        log_structured(
            "Failed to get Entra ID token",
            severity='ERROR',
            error=str(e),
            audience=audience
        )
        raise


def get_aws_credentials():
    """Get AWS credentials using an Entra ID OIDC JWT (no static keys)"""
    role_arn = os.environ['AWS_ROLE_ARN']
    audience = os.environ['AWS_OIDC_AUDIENCE']

    id_token = get_entra_id_token(audience)

    sts_client = boto3.client('sts', region_name=os.environ['AWS_REGION'])

    response = sts_client.assume_role_with_web_identity(
        RoleArn=role_arn,
        RoleSessionName='azure-to-s3-session',
        WebIdentityToken=id_token,
        DurationSeconds=3600
    )

    return response['Credentials']


def get_s3_client():
    """S3 client using the temporary credentials from the OIDC role assume."""
    aws_creds = get_aws_credentials()
    return boto3.client(
        's3',
        region_name=os.environ['AWS_REGION'],
        aws_access_key_id=aws_creds['AccessKeyId'],
        aws_secret_access_key=aws_creds['SecretAccessKey'],
        aws_session_token=aws_creds['SessionToken']
    )


def key_passes_filter(key, prefixes=None, include_regex=None, exclude_regex=None):
    """Check whether an object key passes the configured key path filters.

    Filters default to the KEY_PREFIXES (comma-separated), KEY_INCLUDE_REGEX,
    and KEY_EXCLUDE_REGEX env vars. All configured filters must pass; unset
    ones are skipped.
    """
    if prefixes is None:
        prefixes = [p for p in os.environ.get('KEY_PREFIXES', '').split(',') if p]
    if include_regex is None:
        include_regex = os.environ.get('KEY_INCLUDE_REGEX', '')
    if exclude_regex is None:
        exclude_regex = os.environ.get('KEY_EXCLUDE_REGEX', '')

    if prefixes and not any(key.startswith(p) for p in prefixes):
        return False
    if include_regex and not re.search(include_regex, key):
        return False
    if exclude_regex and re.search(exclude_regex, key):
        return False
    return True


def build_dest_key(object_name):
    """S3 destination key: S3_KEY_PREFIX + object name."""
    prefix = os.environ.get('S3_KEY_PREFIX', '').strip('/')
    return f"{prefix}/{object_name}" if prefix else object_name


def check_s3_object_exists(s3_client, bucket, key):
    """Whether an object already exists in S3."""
    try:
        s3_client.head_object(Bucket=bucket, Key=key)
        return True
    except s3_client.exceptions.ClientError as e:
        if e.response['Error']['Code'] == '404':
            return False
        raise


class BlobStreamReader:
    """File-like read(size) adapter over an azure-storage-blob download stream.

    Turns the SDK's chunk iterator into the read(size) interface boto3's
    upload_fileobj expects.

    NOTE: the Azure SDK's HTTP transport transparently DECOMPRESSES downloads
    of blobs stored with Content-Encoding: gzip (verified empirically - a
    470-byte gzip staging blob reads back as its 645-byte plain content), so
    callers always see decoded bytes and transfer_blob_to_s3 re-compresses
    them on the fly.
    """
    def __init__(self, downloader):
        self.chunks = downloader.chunks()
        self.buffer = b''
        self.finished = False
        self.bytes_written = 0  # bytes output

    def read(self, size=-1):
        try:
            if size == -1:
                for chunk in self.chunks:
                    self.buffer += chunk
                self.finished = True
                result = self.buffer
                self.buffer = b''
                self.bytes_written += len(result)
                return result

            while len(self.buffer) < size and not self.finished:
                try:
                    self.buffer += next(self.chunks)
                except StopIteration:
                    self.finished = True
                    break

            result = self.buffer[:size]
            self.buffer = self.buffer[size:]
            self.bytes_written += len(result)
            return result

        except Exception as e:
            # Never return b'' here: boto3 treats an empty read as EOF, so
            # swallowing an error would silently truncate the upload and
            # record it as a success. Raising makes transfer_blob_to_s3 fail
            # loudly instead, which the retry paths (Event Grid redelivery,
            # sweep function) are built to recover from.
            log_structured("Error reading from blob storage", severity='ERROR', error=str(e))
            raise


class AzureBlobRef:
    """Adapter giving a BlobClient the attribute surface transfer_blob_to_s3 needs.

    Raises azure.core.exceptions.ResourceNotFoundError if the blob is gone.
    """
    def __init__(self, blob_client):
        self.client = blob_client
        props = blob_client.get_blob_properties()
        self.name = blob_client.blob_name
        self.container_name = blob_client.container_name
        self.account_name = blob_client.account_name
        self.size = props.size
        self.content_type = props.content_settings.content_type
        self.content_encoding = props.content_settings.content_encoding
        self.creation_time = props.creation_time

    def open(self):
        return BlobStreamReader(self.client.download_blob())

    def delete(self):
        self.client.delete_blob()


# File extensions that are already compressed - upload as-is, no gzip re-compression
ALREADY_COMPRESSED_EXTENSIONS = ('.gz', '.gzip', '.zip', '.bz2', '.zst', '.snappy', '.parquet')

# Transfer modes for decide_transfer_mode
MODE_RAW_GZIP = 'raw-gzip'    # stored gzip: SDK decompresses on download, re-gzip, ContentEncoding: gzip
MODE_VERBATIM = 'verbatim'    # already-compressed file: stream verbatim, no ContentEncoding
MODE_COMPRESS = 'compress'    # plain data: gzip on the fly, ContentEncoding: gzip


def decide_transfer_mode(object_name, content_encoding):
    """Pick how a blob's bytes should be shipped to S3.

    - Blobs stored with Content-Encoding: gzip keep the gzip encoding on S3.
      (The Azure SDK auto-decompresses such downloads, so the stream is
      re-compressed on the fly; content is identical after decompression.)
    - Blobs whose filename says they are already compressed are copied
      byte-for-byte with no ContentEncoding header.
    - Everything else is gzip-compressed on the fly.
    """
    if content_encoding == 'gzip':
        return MODE_RAW_GZIP
    if object_name.lower().endswith(ALREADY_COMPRESSED_EXTENSIONS):
        return MODE_VERBATIM
    return MODE_COMPRESS


def content_type_for(object_name, blob_content_type):
    """Determine the S3 ContentType for a transferred object.

    Case-insensitive, matching decide_transfer_mode's extension handling."""
    name = object_name.lower()
    stripped = name[:-3] if name.endswith('.gz') else name
    if stripped.endswith('.jsonl') or stripped.endswith('.ndjson'):
        return 'application/x-ndjson'
    return blob_content_type or 'application/octet-stream'


def transfer_blob_to_s3(blob, s3_client, target_bucket, transferred_by='unknown',
                        dest_key=None, delete_source=True):
    """Stream a blob from Azure Blob Storage to S3, handling compression.

    Returns a dict with status and metadata, or None on error.

    transferred_by is recorded in the S3 object metadata; dest_key defaults to
    the blob name. delete_source removes the source blob after a successful
    upload - False for mirror pipelines that copy from customer-owned
    containers.
    """
    try:
        object_name = blob.name
        target_key = dest_key if dest_key else object_name

        # First write wins: an existing S3 key is never re-uploaded. Scanner
        # indexes each S3 key exactly once, so a re-copy would never be
        # re-indexed; this also makes redeliveries and replays idempotent.
        if check_s3_object_exists(s3_client, target_bucket, target_key):
            if delete_source:
                blob.delete()
            return {'status': 'already_exists', 'object': target_key}

        content_type = content_type_for(object_name, blob.content_type)
        source_encoding = blob.content_encoding
        mode = decide_transfer_mode(object_name, source_encoding)
        was_gzipped = mode == MODE_RAW_GZIP
        source_size = blob.size

        metadata = {
            'source-account': blob.account_name,
            'source-container': blob.container_name,
            'source-size': str(source_size),
            'original-encoding': source_encoding or 'none',
            'transferred-by': transferred_by
        }

        if mode == MODE_RAW_GZIP:
            # Stored gzip - the Azure SDK transparently decompresses the
            # download, so re-compress on the fly and keep the gzip
            # ContentEncoding on the S3 object (content is identical after
            # decompression; the exact gzip bytes may differ).
            compressed_stream = GzipStreamWrapper(blob.open())
            s3_client.upload_fileobj(
                compressed_stream,
                target_bucket,
                target_key,
                ExtraArgs={
                    'ContentEncoding': 'gzip',
                    'ContentType': content_type,
                    'Metadata': metadata
                }
            )
            output_size = compressed_stream.bytes_written
        elif mode == MODE_VERBATIM:
            # Already-compressed file (e.g. raw .gz logs) - copy bytes
            # verbatim, no re-compression or ContentEncoding header.
            stream = blob.open()
            s3_client.upload_fileobj(
                stream,
                target_bucket,
                target_key,
                ExtraArgs={
                    'ContentType': content_type,
                    'Metadata': metadata
                }
            )
            output_size = source_size
        else:
            # Plain data - gzip on the fly.
            compressed_stream = GzipStreamWrapper(blob.open())
            s3_client.upload_fileobj(
                compressed_stream,
                target_bucket,
                target_key,
                ExtraArgs={
                    'ContentEncoding': 'gzip',
                    'ContentType': content_type,
                    'Metadata': metadata
                }
            )
            output_size = compressed_stream.bytes_written

        # Delete the source blob after a successful upload (skipped for mirror
        # pipelines).
        if delete_source:
            blob.delete()

        return {
            'status': 'success',
            'object': target_key,
            'gzip_input': was_gzipped,
            'input_size': source_size,
            'output_size': output_size,
            'source_container': blob.container_name,
            'target_bucket': target_bucket
        }

    except Exception as e:
        log_structured(
            "Transfer failed",
            severity='ERROR',
            error=str(e),
            object=blob.name,
            container=blob.container_name
        )
        return None


# ============================================================================
# Event Hub batching helpers (pure functions, unit-tested in test_shared.py)
# ============================================================================

# Maximum NDJSON bytes per staging blob (and per record)
MAX_BATCH_SIZE = 5 * 1024 * 1024


def unroll_records(message_body):
    """Unroll an Event Hub message (str, bytes, or dict) into log records.

    Azure diagnostic settings wrap log entries in a {"records": [...]}
    envelope; each record becomes its own event, and messages without a
    records array are kept whole. Returns a list of dicts (empty for
    malformed/empty messages).
    """
    if isinstance(message_body, (bytes, bytearray)):
        try:
            message_body = message_body.decode('utf-8')
        except UnicodeDecodeError:
            log_structured("Skipped: message is not valid UTF-8", severity='WARNING')
            return []
    if isinstance(message_body, str):
        try:
            message_body = json.loads(message_body)
        except ValueError:
            log_structured(
                "Skipped: message is not valid JSON",
                severity='WARNING',
                body_prefix=message_body[:200]
            )
            return []
    if not isinstance(message_body, dict):
        # e.g. a bare JSON array or scalar - not an expected envelope shape
        log_structured("Skipped: message is not a JSON object", severity='WARNING')
        return []

    records = message_body.get('records')
    if isinstance(records, list):
        return [r for r in records if isinstance(r, dict)]
    return [message_body]


def records_to_ndjson_batches(records, max_batch_bytes=MAX_BATCH_SIZE):
    """Serialize records to NDJSON, split into size-capped batches.

    Returns a list of bytes objects, each a valid NDJSON document no larger
    than max_batch_bytes (every line ends with a newline). Records that exceed
    the cap on their own are skipped with a warning.
    """
    batches = []
    current = []
    current_size = 0

    for record in records:
        line = json.dumps(record, separators=(',', ':')).encode('utf-8') + b'\n'
        if len(line) > max_batch_bytes:
            log_structured(
                "Skipped: record exceeds max batch size",
                severity='WARNING',
                record_size=len(line),
                max_batch_bytes=max_batch_bytes
            )
            continue
        if current_size + len(line) > max_batch_bytes and current:
            batches.append(b''.join(current))
            current = []
            current_size = 0
        current.append(line)
        current_size += len(line)

    if current:
        batches.append(b''.join(current))
    return batches


def build_staging_blob_name(log_prefix, now, unique_id=None):
    """Build a staging blob name: {log_prefix}/YYYY/MM/DD/hh/mm_ssZ_<id>.json.gz

    Matches the GCP pipeline's filename datetime scheme so S3 keys look the
    same across clouds.
    """
    if unique_id is None:
        unique_id = uuid.uuid4().hex[:12]
    prefix = log_prefix.strip('/')
    timestamp = now.strftime('%Y/%m/%d/%H/%M_%S')
    name = f"{timestamp}Z_{unique_id}.json.gz"
    return f"{prefix}/{name}" if prefix else name


def gzip_bytes(data):
    """Gzip a bytes payload (used for staging blob bodies)."""
    compressor = zlib.compressobj(wbits=16 + zlib.MAX_WBITS)
    return compressor.compress(data) + compressor.flush()


def parse_blob_created_subject(subject):
    """Parse an Event Grid BlobCreated subject into (container, blob_name).

    Subjects look like:
      /blobServices/default/containers/<container>/blobs/<path/to/blob>

    Returns (None, None) for anything that doesn't match.
    """
    match = re.match(r'^/blobServices/default/containers/([^/]+)/blobs/(.+)$', subject or '')
    if not match:
        return None, None
    return match.group(1), match.group(2)
