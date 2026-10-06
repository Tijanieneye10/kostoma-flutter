# Changelog

## 0.1.0

First version.

- `identify`, `track`, `registerDevice`, `removeDevice`, `reset` and `flush`.
- Calls are kept in a queue saved on the device and sent in order.
- Network errors, 5xx, 408 and 429 are retried with capped exponential backoff; 429 waits for `Retry-After`.
- Any other answer from the API drops the call and reports it to the logger.
- Events tracked before anyone is identified are held and sent after `identify`.
