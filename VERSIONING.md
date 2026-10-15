# Versions and compatibility

This says what a version number promises, so you can upgrade without reading the code, and how the SDK and the Kostoma API are kept from breaking each other.

## What the number means

The version is `MAJOR.MINOR.PATCH`, as in [Semantic Versioning](https://semver.org).

| You are on | A new | May contain | Safe to take without reading the changelog |
| ---------- | ----- | ----------- | ------------------------------------------ |
| 1.0.0 or later | PATCH (1.2.3 to 1.2.4) | Fixes only | Yes |
| 1.0.0 or later | MINOR (1.2.3 to 1.3.0) | New things; nothing you use changes | Yes |
| 1.0.0 or later | MAJOR (1.2.3 to 2.0.0) | Changes you have to act on | No: read the changelog first |
| 0.x | PATCH (0.1.0 to 0.1.1) | Fixes only | Yes |
| 0.x | MINOR (0.1.0 to 0.2.0) | May change or remove something | No: read the changelog first |

While the version starts with 0, the SDK is still settling, and a new MINOR is where a breaking change goes. That is the usual rule for 0.x versions, and it is the one Dart's own `^` constraint follows: `^0.1.0` takes 0.1.1 and never 0.2.0.

A change counts as breaking when an app that compiled and worked before would not compile, or would behave differently, after upgrading without any edit. Removing or renaming something public, changing what a call sends, and raising the minimum Dart or Flutter version are all breaking.

## Pin the version you install

Depend on a tag, never on a branch. A tag never moves; the main branch does.

```yaml
dependencies:
  kostoma:
    git:
      url: https://github.com/Tijanieneye10/kostoma-flutter.git
      ref: v0.1.1
```

Your `pubspec.lock` then records the exact commit, and nothing changes until you change `ref` yourself.

## The SDK and the API

The SDK calls version 1 of the Kostoma API (`/api/v1`). Two rules keep them working together:

- **The API does not break a released SDK.** Version 1 of the API only gains things: a field or an endpoint may be added, but none the SDK uses is removed, renamed or given a new meaning. A change that could not keep that promise would be a new API version at a new address, with version 1 left running.
- **Every released SDK version is tested against the API.** `compat/requests.json` records exactly what this version sends. A copy for each released version is kept in the Kostoma repository, where a test sends every recorded request to the real API on every change. A change to the API that would break an SDK somebody already installed fails that test before it ships.

| SDK | API | Needs Dart | Needs Flutter |
| --- | --- | ---------- | ------------- |
| 0.1.x | v1 | 3.3 | 3.19 |

Each request carries the SDK's version in the `X-Kostoma-Sdk` header (for example `flutter/0.1.0`), so whoever runs a Kostoma can see which versions are still in use.

## Old versions

A version is never deleted or re-tagged. When one has a fault that matters, a fixed PATCH is released and the changelog says which versions to leave.
