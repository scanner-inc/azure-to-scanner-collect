const { app } = require('@azure/functions');

// Environment
const SCANNER_COLLECT_URL = process.env.SCANNER_COLLECT_URL;
const SCANNER_BEARER_TOKEN = process.env.SCANNER_BEARER_TOKEN;
const EVENTHUB_NAME = process.env.EVENTHUB_NAME;

if (!SCANNER_COLLECT_URL || !SCANNER_BEARER_TOKEN) {
  throw new Error('SCANNER_COLLECT_URL and SCANNER_BEARER_TOKEN must be set as app settings.');
}

// Helpers
class NonRetryableError extends Error {}   // marker class

async function retryWithBackoff(
  fn,
  maxRetries,
  baseDelay,
  ctx // pass context for logging
) {
  let attempt = 0;

  while (attempt < maxRetries) {
    try {
      const res = await fn();

      // Success
      if (res.status >= 200 && res.status < 300) {
        await res.text(); // Consume response body
        return;
      }

      // Get error response for context
      const errorBody = await res.text();
      const truncatedError = errorBody.length > 1024 ? errorBody.substring(0, 1024) + '...' : errorBody;

      // 4xx: never retry
      if (res.status >= 400 && res.status < 500) {
        throw new NonRetryableError(`HTTP ${res.status}: ${truncatedError}`);
      }

      // 5xx: throw to trigger retry
      throw new Error(`HTTP ${res.status}: ${truncatedError}`);
    } catch (err) {
      // Handle timeout errors specifically
      if (err.name === 'TimeoutError' || err.code === 'TimeoutError') {
        ctx.warn(`Request timed out after 30 seconds`);
        err = new Error('Request timeout (30s)');
      }
      
      // Abort immediately on non-retryable error
      if (err instanceof NonRetryableError) {
        ctx.error(`Stopped: ${err.message}`);
        throw err;
      }

      attempt++;
      if (attempt >= maxRetries) {
        ctx.error(`Attempts exhausted (${maxRetries}). Last error: ${err.message}`);
        throw err;
      }

      const delay = baseDelay * 2 ** (attempt - 1);
      ctx.warn(`Attempt ${attempt} failed (${err.message}). Retrying in ${delay} ms...`);
      await new Promise(r => setTimeout(r, delay));
    }
  }
}

// Event Hub trigger
app.eventHub('scanner-collect-eventhub-trigger', {
  connection: 'EVENTHUB_CONNECTION_STRING',
  eventHubName: EVENTHUB_NAME,
  cardinality: 'many',

  handler: async (messages, context) => {
    // Always work with an array
    if (!Array.isArray(messages)) messages = [messages];

    // Convert messages to JSON strings
    const jsonMessages = messages.map(m => (typeof m === 'string' ? m : JSON.stringify(m)));

    // Batch messages to stay under 5MB per request
    const MAX_BATCH_SIZE = 5 * 1024 * 1024; // 5MB
    
    // Filter out oversized messages
    const validMessages = [];
    for (const message of jsonMessages) {
      const messageSize = Buffer.byteLength(message, 'utf8');
      if (messageSize > MAX_BATCH_SIZE) {
        context.warn(`Message exceeds 5MB limit (${messageSize} bytes), skipping`);
      } else {
        validMessages.push(message);
      }
    }
    
    // Early return if no valid messages
    if (validMessages.length === 0) {
      context.warn('No valid messages to send after filtering oversized messages');
      return;
    }
    
    const batches = [];
    let currentBatch = [];
    let currentSize = 0;

    for (const message of validMessages) {
      const messageSize = Buffer.byteLength(message, 'utf8') + 1; // +1 for newline

      if (currentSize + messageSize > MAX_BATCH_SIZE && currentBatch.length > 0) {
        // Start a new batch
        batches.push(currentBatch);
        currentBatch = [message];
        currentSize = messageSize;
      } else {
        currentBatch.push(message);
        currentSize += messageSize;
      }
    }

    // Add the last batch if it has messages
    if (currentBatch.length > 0) {
      batches.push(currentBatch);
    }

    // Send each batch
    let totalSent = 0;
    for (const [index, batch] of batches.entries()) {
      const payload = batch.join('\n');

      const requestFn = () =>
        fetch(SCANNER_COLLECT_URL, {
          method: 'POST',
          headers: {
            Authorization: `Bearer ${SCANNER_BEARER_TOKEN}`,
            'Content-Type': 'application/x-ndjson'
          },
          body: payload,
          signal: AbortSignal.timeout(30000)
        });

      const maxRetries = 5;
      const baseDelay = 500; // 500ms
      await retryWithBackoff(requestFn, maxRetries, baseDelay, context);
      totalSent += batch.length;

      if (batches.length > 1) {
        context.log(`Successfully sent batch ${index + 1}/${batches.length} (${batch.length} messages) to ${SCANNER_COLLECT_URL}`);
      }
    }

    context.log(`Successfully sent ${totalSent} messages in ${batches.length} batch(es) to ${SCANNER_COLLECT_URL}`);
  }
});
