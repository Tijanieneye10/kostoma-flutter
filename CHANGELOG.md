# Changelog

Every change that someone using the SDK could notice is listed here, newest first. Versions follow [Semantic Versioning](https://semver.org); what that means for this package is in [VERSIONING.md](VERSIONING.md).

## 0.1.1

- The SDK is now published under the MIT license, so it can be used, changed and shipped in your app. See [LICENSE](LICENSE).
- Nothing the SDK does or sends has changed.

## 0.1.0

First version.

- `identify`, `track`, `registerDevice`, `removeDevice`, `reset` and `flush`.
- Calls are kept in a queue saved on the device and sent in order.
- Network errors, 5xx, 408 and 429 are retried with capped exponential backoff; 429 waits for `Retry-After`.
- Any other answer from the API drops the call and reports it to the logger.
- Events tracked before anyone is identified are held and sent after `identify`.
- Every request carries the SDK's version in the `X-Kostoma-Sdk` header.
