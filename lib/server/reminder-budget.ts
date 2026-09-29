// Five worst-case deliveries: 2 DB calls + provider = 20s each.
// Discovery + claim = 10s; reserve 10s for bookkeeping/response.
// 120s soft < 180s Vercel hard < 300s DB lease.
export const HANDLER_BUDGET_MS = 120_000;
export const PROVIDER_TIMEOUT_MS = 10_000;
export const DB_OPERATION_TIMEOUT_MS = 5_000;
export const MAX_CLAIMS_PER_RUN = 5;
export const FINISH_MARGIN_MS = 10_000;
export const DELIVERY_BUDGET_MS = 2 * DB_OPERATION_TIMEOUT_MS + PROVIDER_TIMEOUT_MS;

export async function emptyReminderBody(request: Request, timeoutMs = DB_OPERATION_TIMEOUT_MS) {
  if (!request.body) return true;
  const reader = request.body.getReader();
  try {
    return await boundedOperation(async signal => {
      signal.addEventListener('abort', () => { void reader.cancel().catch(() => {}); }, { once: true });
      for (;;) {
        const chunk = await reader.read();
        signal.throwIfAborted();
        if (chunk.value?.byteLength) return false;
        if (chunk.done) return true;
      }
    }, timeoutMs);
  } finally {
    void reader.cancel().catch(() => {});
    reader.releaseLock();
  }
}

// Race bounds even a non-cooperative transport; abort also cancels supported I/O.
// A timed-out external send is uncertain, never evidence that it did not happen.
export async function boundedOperation<T>(
  operation: (signal: AbortSignal) => PromiseLike<T>, timeoutMs: number,
): Promise<T> {
  const controller = new AbortController();
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      Promise.resolve().then(() => operation(controller.signal)),
      new Promise<never>((_, reject) => {
        timer = setTimeout(() => {
          controller.abort();
          reject(new Error('Reminder operation timed out'));
        }, timeoutMs);
      }),
    ]);
  } finally { clearTimeout(timer); }
}
