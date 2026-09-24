import { setTimeout as delay } from 'node:timers/promises';
import { dangerouslyDeleteByTag } from '@vercel/functions';

export const RELAY_CACHE_TAG = 'fourthciv-relay-v1';
export const RELAY_CACHE_TTL = 3600;
export const RELAY_CACHE_READ_TIMEOUT_MS = 4000;
export const RELAY_CACHE_DRAIN_MS = 5000;
const PURGE_TIMEOUT_MS = 3000;
const RETRY_DELAYS_MS = [100, 250];

export class CachePurgeError extends Error {
  constructor(code) {
    super('Relay cache purge unavailable');
    this.name = 'CachePurgeError';
    this.code = code;
  }
}

function deleteRuntimeTag(tag, options) {
  // @vercel/functions 3.9.9 otherwise silently succeeds outside the runtime.
  // Check the same request-scoped capability used by its getContext() helper;
  // do not substitute an operator token or a cross-environment REST request.
  const context = globalThis[Symbol.for('@vercel/request-context')]?.get?.();
  if (typeof context?.purge?.dangerouslyDeleteByTag !== 'function') {
    throw new CachePurgeError('runtime-unavailable');
  }
  return dangerouslyDeleteByTag(tag, options);
}

function withinSignal(operation, signal) {
  return new Promise((resolve, reject) => {
    if (signal.aborted) { reject(signal.reason); return; }
    const aborted = () => reject(signal.reason);
    signal.addEventListener('abort', aborted, { once: true });
    Promise.resolve().then(() => {
      signal.throwIfAborted();
      return operation();
    }).then(resolve, reject).finally(() => signal.removeEventListener('abort', aborted));
  });
}

// Timing overrides are injectable test dependencies, never environment settings.
export function createRelayCache({ deleteByTag = deleteRuntimeTag, drainMs = RELAY_CACHE_DRAIN_MS, timeoutMs = PURGE_TIMEOUT_MS,
  retryDelaysMs = RETRY_DELAYS_MS } = {}) {
  return Object.freeze({
    tag: RELAY_CACHE_TAG,
    ttl: RELAY_CACHE_TTL,
    readTimeoutMs: RELAY_CACHE_READ_TIMEOUT_MS,
    async purge({ signal } = {}) {
      // Called only after the write commits. Let older origin reads finish or
      // hit the shorter read deadline before deleting the tag. This mitigation
      // must also run for duplicate retries that repair a lost acknowledgement.
      // The caller's overall request deadline includes both drain and purge.
      try {
        if (signal?.aborted) throw new CachePurgeError('aborted');
        await delay(drainMs, undefined, { signal });
        if (signal?.aborted) throw new CachePurgeError('aborted');
      } catch {
        throw new CachePurgeError('aborted');
      }
      // Start the SDK retry budget after draining, not at request/commit time.
      const timeout = new AbortController();
      const timer = setTimeout(() => timeout.abort(), timeoutMs);
      const deadline = signal ? AbortSignal.any([signal, timeout.signal]) : timeout.signal;
      const interrupted = () => new CachePurgeError(signal?.aborted ? 'aborted' : 'timeout');
      try {
        for (let attempt = 0; attempt <= retryDelaysMs.length; attempt += 1) {
          if (deadline.aborted) throw interrupted();
          try {
            // Zero means no stale-serving grace; it is not a network timeout.
            // The SDK has no AbortSignal argument. Stop awaiting on cancellation
            // but never retry an unresolved operation, which may finish later.
            await withinSignal(() => deleteByTag(RELAY_CACHE_TAG, { revalidationDeadlineSeconds: 0 }), deadline);
            if (deadline.aborted) throw interrupted();
            return;
          } catch (error) {
            if (deadline.aborted) throw interrupted();
            if (error instanceof CachePurgeError && error.code === 'runtime-unavailable') throw error;
            if (attempt === retryDelaysMs.length) throw new CachePurgeError('unavailable');
            await delay(retryDelaysMs[attempt], undefined, { signal: deadline });
          }
        }
      } catch (error) {
        // Never retain provider error messages, response bodies, or abort reasons.
        if (deadline.aborted) throw interrupted();
        if (error instanceof CachePurgeError) throw error;
        throw new CachePurgeError('unavailable');
      } finally {
        clearTimeout(timer);
      }
    },
  });
}

export const relayCache = createRelayCache();
