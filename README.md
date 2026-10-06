# Kostoma for Flutter

The Kostoma SDK for Flutter apps. It tells your Kostoma workspace who is using the app, what they do in it, and which device to send their push notifications to, so you do not write those HTTP calls yourself.

It covers four things:

- `identify`: create or update a person.
- `track`: record that the person did something.
- `registerDevice` and `removeDevice`: store or forget a push token.
- `reset`: sign the person out of the device.

It cannot send messages. That is on purpose: see "The API key" below.

## Installing

The package is not on pub.dev yet. Add it from git, pinned to a version tag:

```yaml
dependencies:
  kostoma:
    git:
      url: https://github.com/Tijanieneye10/kostoma-flutter.git
      ref: v0.1.0
```

Pin a tag, not a branch: a tag never moves, so your app gets a new version only when you change `ref`. What a version number promises, and which versions of the SDK work with which API, is in [VERSIONING.md](VERSIONING.md). What changed in each version is in [CHANGELOG.md](CHANGELOG.md).

It needs Dart 3.3 or later and Flutter 3.19 or later.

## The API key

In Kostoma, go to Settings, API keys, and create a key with Access set to "Data only".

Use a data-only key in the app, never one with full access. Anything shipped inside an app can be read out of it. A data-only key can identify people, track events and register devices, and nothing else. A full key can also send messages, start broadcasts and change segments, so whoever found one could message your customers in your name.

## Initialising

Call `Kostoma.initialize` once, before `runApp`:

```dart
import 'package:flutter/widgets.dart';
import 'package:kostoma/kostoma.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  Kostoma.initialize(
    apiKey: 'your-data-only-key',
    baseUrl: Uri.parse('https://kostoma.example.com'),
  );

  runApp(const MyApp());
}
```

`baseUrl` is the address of your Kostoma, without `/api/v1`. After this, use `Kostoma.instance` anywhere.

If you would rather not use a shared instance, make your own with `Kostoma(apiKey: ..., baseUrl: ...)` and pass it around. It behaves the same. Make only one over the same storage.

## Identifying a person

Call `identify` when the person signs in, and again whenever something you know about them changes.

```dart
Kostoma.instance.identify(
  'u_1042',
  email: 'ada@example.com',
  attributes: {
    'first_name': 'Ada',
    'kyc_level': 2,
    'is_verified': true,
    'timezone': 'Africa/Lagos',
  },
);
```

- The first argument is your own identifier for the person. It is remembered on the device until `reset`.
- Attributes are merged into the ones Kostoma already has. Send an attribute as `null` to remove it.
- Four attribute names are reserved: `created_at` (when the person signed up), `unsubscribed` (true or false), `timezone` (an IANA name such as `Africa/Lagos`) and `email`.
- A `DateTime` among the attributes is sent as Unix seconds.

## Tracking events

```dart
Kostoma.instance.track('bvn_verified', data: {'kyc_id': 'kyc_88213'});
```

- Event names are case-sensitive.
- Each event is stamped with the time on the device when `track` was called, so an event that is sent late is still recorded at the time it happened. Pass `timestamp:` to give a different time.
- Each event carries its own identifier, so one that is sent twice after a lost connection is stored once.

### Before anyone is signed in

The Kostoma API has no anonymous people: every event needs a person. Events tracked while nobody is identified are kept on the device and sent, with their original times, straight after the next `identify`. Until then Kostoma does not have them, and if nobody ever signs in they are never sent.

## Push notifications

The SDK does not depend on Firebase. Your app gets its FCM token with `firebase_messaging` and hands it over. Kostoma delivers push through your own Firebase project (upload its service account key under Settings, Push), so pass the FCM token on both Android and iOS.

```dart
import 'dart:io' show Platform;

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:kostoma/kostoma.dart';

Future<void> setUpPush() async {
  final messaging = FirebaseMessaging.instance;
  await messaging.requestPermission();

  final platform = Platform.isIOS
      ? KostomaDevicePlatform.ios
      : KostomaDevicePlatform.android;

  final token = await messaging.getToken();
  if (token != null) {
    Kostoma.instance.registerDevice(token, platform: platform);
  }

  messaging.onTokenRefresh.listen((newToken) {
    Kostoma.instance.registerDevice(newToken, platform: platform);
  });
}
```

- Call this at every app start. Registering the same token again only refreshes when the device was last used.
- When the token changes, the SDK removes the old one from Kostoma and registers the new one.
- If nobody is identified yet, the token is remembered and registered for whoever is identified next. You do not have to order `identify` and `registerDevice` yourself.
- A token belongs to one person at a time. Identifying someone else on the same phone moves it to them.

To stop push to a device without signing out, call `Kostoma.instance.removeDevice(token)`.

## Signing out

```dart
await Kostoma.instance.reset();
```

`reset` removes the device from the person, so the next user of the phone does not receive their pushes, and forgets who the current person is. Then:

- Events tracked after it are held until the next `identify`, as before anyone signed in.
- The push token stays on the device, tied to nobody, and is registered for the next person identified. You do not need to call `registerDevice` again.
- Calls made before `reset` that have not been sent yet are still sent. They stay in the queue, with the person's identifier in them, until they are.

If the phone is offline when `reset` is called, the removal waits in the queue like any other call, and Kostoma may still push to the device until it arrives.

## What happens offline

No method waits on the network, and none throws because of it. Each call is added to a queue saved on the device (with `shared_preferences`), and one sender works through the queue in order. An `identify` always arrives before the events tracked after it.

- The future a method returns completes when the call is saved, not when it is sent. You do not need to await it.
- The queue survives the app being closed. Sending carries on at the next start.
- A call that fails because of the network, a server error (5xx), a timeout (408) or the rate limit (429) is tried again: after 2 seconds, then 4, then 8, doubling up to 5 minutes. For 429 the SDK waits the number of seconds in the `Retry-After` header.
- The queue holds 1,000 calls. When it is full, the oldest call is dropped to make room, so a phone that is offline for weeks does not fill its storage.
- `Kostoma.instance.flush()` tries to send what is waiting now, without waiting out a retry delay. A good moment is when the app comes back to the foreground.

The queue size, the delays and the request timeout can be changed in `Kostoma.initialize`.

## Errors

A call the API refuses in a way that trying again cannot fix is dropped, so it does not block the calls behind it. That is any 4xx answer other than 408 and 429, for example:

- 401: the key is wrong, revoked or expired.
- 403: the key may not use that address.
- 422: the body is invalid, for example an email address that is not one.

Dropped calls, retries and storage problems are reported to the `logger` you pass to `initialize`:

```dart
Kostoma.initialize(
  apiKey: 'your-data-only-key',
  baseUrl: Uri.parse('https://kostoma.example.com'),
  logger: (event) {
    if (event.dropped) {
      // event.statusCode, event.error?.code and event.error?.details say why.
      myErrorReporter.report(event.message);
    }
  },
);
```

`event.message` never contains personal data, the API key or the request body. `event.call` is the call itself, and `event.error` is the API's answer; both can contain personal data, so think before you write them to a log.

Without a logger, warnings and errors are printed with `debugPrint` in debug builds only, and nothing is printed in release builds.

Three things are reported and ignored without being queued: an empty id, event name or token, and attributes or event data that cannot be turned into JSON.

`Kostoma.instance` throws a `StateError` if `initialize` has not been called. Nothing else in the SDK throws.

## Testing your app

Pass `store: InMemoryKostomaStore()` and an `httpClient` from `package:http/testing.dart` to keep tests off the disk and the network:

```dart
final kostoma = Kostoma(
  apiKey: 'test',
  baseUrl: Uri.parse('https://kostoma.example.com'),
  httpClient: MockClient((request) async => http.Response('{"status":"accepted"}', 202)),
  store: InMemoryKostomaStore(),
);
```

## What it does not do yet

- No in-app messages.
- No automatic screen tracking. Call `track` yourself where it matters.
- No anonymous people. Events before sign-in wait on the device, as described above.
- No retry limit for a server that keeps answering 5xx to one call. The call is retried, at most every 5 minutes, until it is accepted or pushed out of the queue.
- No SDKs for the web or for native iOS and Android yet. Flutter is the first.
