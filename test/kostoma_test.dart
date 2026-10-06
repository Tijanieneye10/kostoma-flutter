import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kostoma/kostoma.dart';

final Uri baseUrl = Uri.parse('https://kostoma.example.com');

/// 2026-09-29T18:09:52Z, which is 1790705392 in Unix seconds.
final DateTime now = DateTime.utc(2026, 9, 29, 18, 9, 52);
const int nowInUnixSeconds = 1790705392;

const Duration oneHour = Duration(hours: 1);

http.Response accepted() => http.Response('{"status":"accepted"}', 202);

http.Response apiError(
  int status,
  String code, {
  Map<String, List<String>>? details,
  Map<String, String> headers = const {},
}) {
  final error = <String, Object?>{'code': code, 'message': 'Refused.'};
  if (details != null) {
    error['details'] = details;
  }
  return http.Response(jsonEncode({'error': error}), status, headers: headers);
}

/// A client that keeps every request it is sent. It answers 202 unless
/// [respond] says otherwise; the attempt number it is given starts at 1.
MockClient recording(
  List<http.Request> requests, [
  http.Response Function(http.Request request, int attempt)? respond,
]) {
  return MockClient((request) async {
    requests.add(request);
    final handler = respond;
    return handler == null ? accepted() : handler(request, requests.length);
  });
}

/// A client with no network.
MockClient offline([List<http.Request>? requests]) {
  return MockClient((request) async {
    requests?.add(request);
    throw http.ClientException('No network.');
  });
}

Map<String, Object?> bodyOf(http.Request request) {
  return Map<String, Object?>.from(jsonDecode(request.body) as Map);
}

List<String> pathsOf(List<http.Request> requests) {
  return [for (final request in requests) request.url.path];
}

/// A client that waits an hour between attempts unless told otherwise, so a
/// test decides when a retry happens by calling flush.
Kostoma build({
  required http.Client client,
  KostomaStore? store,
  List<KostomaLogEvent>? events,
  Duration initialBackoff = oneHour,
  Duration maxBackoff = oneHour,
  int maxQueueSize = 1000,
}) {
  final kostoma = Kostoma(
    apiKey: 'kst_test_key',
    baseUrl: baseUrl,
    httpClient: client,
    store: store ?? InMemoryKostomaStore(),
    logger: (event) => events?.add(event),
    initialBackoff: initialBackoff,
    maxBackoff: maxBackoff,
    maxQueueSize: maxQueueSize,
    clock: () => now,
  );
  addTearDown(kostoma.close);
  return kostoma;
}

/// Flush until nothing is waiting.
Future<void> drain(Kostoma kostoma) async {
  for (var i = 0; i < 50; i++) {
    await kostoma.flush();
    if (await kostoma.pendingCount() == 0) {
      return;
    }
  }
  fail('The queue did not empty.');
}

/// Wait, without flushing, until nothing is waiting.
Future<void> settle(Kostoma kostoma) async {
  for (var i = 0; i < 200; i++) {
    if (await kostoma.pendingCount() == 0) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('The queue did not empty.');
}

void main() {
  group('request shape', () {
    test('identify sends the id, email and attributes', () async {
      final requests = <http.Request>[];
      final kostoma = build(client: recording(requests));

      await kostoma.identify(
        'u_1042',
        email: 'ada@example.com',
        attributes: {'first_name': 'Ada', 'kyc_level': 2, 'referral': null},
      );
      await kostoma.flush();

      expect(requests, hasLength(1));
      final request = requests.single;
      expect(request.method, 'POST');
      expect(
        request.url.toString(),
        'https://kostoma.example.com/api/v1/identify',
      );
      expect(request.headers['Authorization'], 'Bearer kst_test_key');
      expect(request.headers['Content-Type'], 'application/json');
      expect(request.headers['Accept'], 'application/json');
      expect(bodyOf(request), {
        'id': 'u_1042',
        'email': 'ada@example.com',
        'attributes': {'first_name': 'Ada', 'kyc_level': 2, 'referral': null},
      });
    });

    test('identify with only an id sends only the id', () async {
      final requests = <http.Request>[];
      final kostoma = build(client: recording(requests));

      await kostoma.identify('u_1');
      await kostoma.flush();

      expect(bodyOf(requests.single), {'id': 'u_1'});
    });

    test('a DateTime attribute is sent as Unix seconds', () async {
      final requests = <http.Request>[];
      final kostoma = build(client: recording(requests));

      await kostoma.identify('u_1', attributes: {'created_at': now});
      await kostoma.flush();

      expect(bodyOf(requests.single)['attributes'], {
        'created_at': nowInUnixSeconds,
      });
    });

    test('track sends the person, the device time and an event id', () async {
      final requests = <http.Request>[];
      final kostoma = build(client: recording(requests));

      await kostoma.identify('u_1042');
      await kostoma.track('bvn_verified', data: {'kyc_id': 'kyc_88213'});
      await kostoma.flush();

      expect(requests, hasLength(2));
      final request = requests.last;
      expect(request.method, 'POST');
      expect(request.url.path, '/api/v1/track');
      expect(request.headers['Authorization'], 'Bearer kst_test_key');
      expect(request.headers['Content-Type'], 'application/json');

      final body = bodyOf(request);
      expect(
        body.keys,
        unorderedEquals(['id', 'name', 'data', 'timestamp', 'event_id']),
      );
      expect(body['id'], 'u_1042');
      expect(body['name'], 'bvn_verified');
      expect(body['data'], {'kyc_id': 'kyc_88213'});
      expect(body['timestamp'], nowInUnixSeconds);
      expect(body['event_id'], isA<String>());
      expect(body['event_id'] as String, isNotEmpty);
    });

    test('track without data leaves data out', () async {
      final requests = <http.Request>[];
      final kostoma = build(client: recording(requests));

      await kostoma.identify('u_1');
      await kostoma.track('login');
      await kostoma.flush();

      expect(
        bodyOf(requests.last).keys,
        unorderedEquals(['id', 'name', 'timestamp', 'event_id']),
      );
    });

    test('track sends the timestamp it is given', () async {
      final requests = <http.Request>[];
      final kostoma = build(client: recording(requests));

      await kostoma.identify('u_1');
      await kostoma.track(
        'login',
        timestamp: now.subtract(const Duration(days: 2)),
      );
      await kostoma.flush();

      expect(
        bodyOf(requests.last)['timestamp'],
        nowInUnixSeconds - 2 * 24 * 60 * 60,
      );
    });

    test('two events have different event ids', () async {
      final requests = <http.Request>[];
      final kostoma = build(client: recording(requests));

      await kostoma.identify('u_1');
      await kostoma.track('login');
      await kostoma.track('login');
      await kostoma.flush();

      expect(
        bodyOf(requests[1])['event_id'],
        isNot(bodyOf(requests[2])['event_id']),
      );
    });

    test('registerDevice sends the person, token and platform', () async {
      final requests = <http.Request>[];
      final kostoma = build(client: recording(requests));

      await kostoma.identify('u_1042');
      await kostoma.registerDevice(
        'fcm_dQw4w9WgXcQ',
        platform: KostomaDevicePlatform.android,
      );
      await kostoma.flush();

      final request = requests.last;
      expect(request.method, 'POST');
      expect(request.url.path, '/api/v1/devices');
      expect(request.headers['Authorization'], 'Bearer kst_test_key');
      expect(request.headers['Content-Type'], 'application/json');
      expect(bodyOf(request), {
        'id': 'u_1042',
        'token': 'fcm_dQw4w9WgXcQ',
        'platform': 'android',
        'last_used': nowInUnixSeconds,
      });
    });

    test('the iOS platform is sent as ios', () async {
      final requests = <http.Request>[];
      final kostoma = build(client: recording(requests));

      await kostoma.identify('u_1');
      await kostoma.registerDevice(
        'tok_1',
        platform: KostomaDevicePlatform.ios,
      );
      await kostoma.flush();

      expect(bodyOf(requests.last)['platform'], 'ios');
    });

    test('removeDevice sends a DELETE with only the token', () async {
      final requests = <http.Request>[];
      final kostoma = build(client: recording(requests));

      await kostoma.removeDevice('fcm_dQw4w9WgXcQ');
      await kostoma.flush();

      final request = requests.single;
      expect(request.method, 'DELETE');
      expect(request.url.path, '/api/v1/devices');
      expect(request.headers['Authorization'], 'Bearer kst_test_key');
      expect(request.headers['Content-Type'], 'application/json');
      expect(bodyOf(request), {'token': 'fcm_dQw4w9WgXcQ'});
    });

    test('a base URL with a path and a trailing slash is kept', () async {
      final requests = <http.Request>[];
      final kostoma = Kostoma(
        apiKey: 'kst_test_key',
        baseUrl: Uri.parse('https://example.com/kostoma/'),
        httpClient: recording(requests),
        store: InMemoryKostomaStore(),
        logger: (event) {},
      );
      addTearDown(kostoma.close);

      await kostoma.identify('u_1');
      await kostoma.flush();

      expect(
        requests.single.url.toString(),
        'https://example.com/kostoma/api/v1/identify',
      );
    });
  });

  group('before anyone is identified', () {
    test('events are held, then sent after identify for that person', () async {
      final requests = <http.Request>[];
      final kostoma = build(client: recording(requests));

      await kostoma.track('app_opened');
      await kostoma.flush();
      expect(requests, isEmpty);

      await kostoma.identify('u_1');
      await kostoma.flush();

      expect(pathsOf(requests), ['/api/v1/identify', '/api/v1/track']);
      final event = bodyOf(requests.last);
      expect(event['id'], 'u_1');
      expect(event['name'], 'app_opened');
      expect(event['timestamp'], nowInUnixSeconds);
    });

    test('held events survive a restart', () async {
      final store = InMemoryKostomaStore();
      final first = build(client: recording([]), store: store);
      await first.track('app_opened');
      first.close();

      final requests = <http.Request>[];
      final second = build(client: recording(requests), store: store);
      await second.identify('u_1');
      await second.flush();

      expect(pathsOf(requests), ['/api/v1/identify', '/api/v1/track']);
      expect(bodyOf(requests.last)['name'], 'app_opened');
    });

    test('a device is registered once someone is identified', () async {
      final requests = <http.Request>[];
      final kostoma = build(client: recording(requests));

      await kostoma.registerDevice(
        'tok_1',
        platform: KostomaDevicePlatform.ios,
      );
      await kostoma.flush();
      expect(requests, isEmpty);

      await kostoma.identify('u_1');
      await kostoma.flush();

      expect(pathsOf(requests), ['/api/v1/identify', '/api/v1/devices']);
      expect(bodyOf(requests.last)['id'], 'u_1');
      expect(bodyOf(requests.last)['token'], 'tok_1');
    });
  });

  group('the queue', () {
    test('keeps the order the calls were made in', () async {
      final requests = <http.Request>[];
      final kostoma = build(client: recording(requests));

      // Not awaited one by one, as an app would call them.
      final calls = [
        kostoma.identify('u_1'),
        kostoma.track('first'),
        kostoma.track('second'),
        kostoma.track('third'),
      ];
      await Future.wait(calls);
      await kostoma.flush();

      expect(pathsOf(requests), [
        '/api/v1/identify',
        '/api/v1/track',
        '/api/v1/track',
        '/api/v1/track',
      ]);
      expect(
        [for (final request in requests.skip(1)) bodyOf(request)['name']],
        ['first', 'second', 'third'],
      );
    });

    test('survives a restart', () async {
      final store = InMemoryKostomaStore();
      final first = build(client: offline(), store: store);
      await first.identify('u_1');
      await first.track('signed_up');
      await first.flush();
      expect(await first.pendingCount(), 2);
      first.close();

      final requests = <http.Request>[];
      final second = build(client: recording(requests), store: store);
      await drain(second);

      expect(pathsOf(requests), ['/api/v1/identify', '/api/v1/track']);
      expect(bodyOf(requests.last)['id'], 'u_1');
      expect(await second.currentPersonId(), 'u_1');
    });

    test('drops the oldest calls when it is full', () async {
      final store = InMemoryKostomaStore();
      final events = <KostomaLogEvent>[];
      final first = build(
        client: offline(),
        store: store,
        events: events,
        maxQueueSize: 3,
      );
      await first.identify('u_1');
      for (var i = 1; i <= 5; i++) {
        await first.track('event_$i');
      }
      await first.flush();

      expect(await first.pendingCount(), 3);
      expect(events.where((event) => event.dropped), isNotEmpty);
      first.close();

      final requests = <http.Request>[];
      final second = build(client: recording(requests), store: store);
      await drain(second);

      expect(
        [for (final request in requests) bodyOf(request)['name']],
        ['event_3', 'event_4', 'event_5'],
      );
    });
  });

  group('retries', () {
    test('a 500 is tried again until it succeeds', () async {
      final requests = <http.Request>[];
      final events = <KostomaLogEvent>[];
      final kostoma = build(
        client: recording(requests, (request, attempt) {
          return attempt < 3 ? apiError(500, 'server_error') : accepted();
        }),
        events: events,
      );

      await kostoma.identify('u_1');
      await kostoma.track('login');
      await drain(kostoma);

      expect(pathsOf(requests), [
        '/api/v1/identify',
        '/api/v1/identify',
        '/api/v1/identify',
        '/api/v1/track',
      ]);
      expect(events.where((event) => event.dropped), isEmpty);
    });

    test('a network error is tried again without flush', () async {
      final requests = <http.Request>[];
      final kostoma = build(
        client: recording(requests, (request, attempt) {
          if (attempt < 3) {
            throw http.ClientException('No network.');
          }
          return accepted();
        }),
        initialBackoff: Duration.zero,
      );

      await kostoma.identify('u_1');
      await settle(kostoma);

      expect(requests, hasLength(3));
    });

    test('the wait doubles after each failure, up to the cap', () async {
      final requests = <http.Request>[];
      final events = <KostomaLogEvent>[];
      final kostoma = build(
        client: recording(requests, (request, attempt) {
          return attempt < 5 ? apiError(503, 'server_error') : accepted();
        }),
        events: events,
        initialBackoff: const Duration(seconds: 2),
        maxBackoff: const Duration(seconds: 10),
      );

      await kostoma.identify('u_1');
      await drain(kostoma);

      expect(
        [
          for (final event in events)
            if (event.retryIn != null) event.retryIn,
        ],
        const [
          Duration(seconds: 2),
          Duration(seconds: 4),
          Duration(seconds: 8),
          Duration(seconds: 10),
        ],
      );
    });

    test('a 429 waits for Retry-After before trying again', () {
      fakeAsync((async) {
        final requests = <http.Request>[];
        final kostoma = Kostoma(
          apiKey: 'kst_test_key',
          baseUrl: baseUrl,
          httpClient: recording(requests, (request, attempt) {
            return attempt == 1
                ? apiError(429, 'rate_limited', headers: {'retry-after': '7'})
                : accepted();
          }),
          store: InMemoryKostomaStore(),
          logger: (event) {},
          initialBackoff: const Duration(seconds: 1),
        );

        kostoma.identify('u_1');
        async.elapse(const Duration(milliseconds: 1));
        expect(requests, hasLength(1));

        async.elapse(const Duration(seconds: 6));
        expect(requests, hasLength(1));

        async.elapse(const Duration(seconds: 2));
        expect(requests, hasLength(2));

        kostoma.close();
      });
    });

    test('a 429 without Retry-After falls back to the backoff', () async {
      final requests = <http.Request>[];
      final events = <KostomaLogEvent>[];
      final kostoma = build(
        client: recording(requests, (request, attempt) {
          return attempt == 1 ? apiError(429, 'rate_limited') : accepted();
        }),
        events: events,
        initialBackoff: const Duration(seconds: 2),
      );

      await kostoma.identify('u_1');
      await drain(kostoma);

      expect(requests, hasLength(2));
      final retry = events.firstWhere((event) => event.retryIn != null);
      expect(retry.statusCode, 429);
      expect(retry.retryIn, const Duration(seconds: 2));
    });
  });

  group('calls that can never succeed', () {
    test('a 401 is dropped and reported, and the queue moves on', () async {
      final requests = <http.Request>[];
      final events = <KostomaLogEvent>[];
      final kostoma = build(
        client: recording(requests, (request, attempt) {
          return attempt == 1 ? apiError(401, 'unauthenticated') : accepted();
        }),
        events: events,
      );

      await kostoma.identify('u_1');
      await kostoma.track('login');
      await kostoma.flush();

      expect(pathsOf(requests), ['/api/v1/identify', '/api/v1/track']);
      expect(await kostoma.pendingCount(), 0);

      final dropped = events.where((event) => event.dropped).single;
      expect(dropped.statusCode, 401);
      expect(dropped.error?.code, 'unauthenticated');
      expect(dropped.call?.type, KostomaCallType.identify);
    });

    test('a 422 is dropped and reported with its details', () async {
      final requests = <http.Request>[];
      final events = <KostomaLogEvent>[];
      final kostoma = build(
        client: recording(requests, (request, attempt) {
          final name = bodyOf(request)['name'];
          if (name is! String || name.length <= 255) {
            return accepted();
          }
          return apiError(
            422,
            'invalid_request',
            details: {
              '/name': ['The property name is too long'],
            },
          );
        }),
        events: events,
      );

      await kostoma.identify('u_1');
      await kostoma.track('x' * 300);
      await kostoma.track('login');
      await kostoma.flush();

      // The bad event was sent once, and the one after it was still sent.
      expect(requests, hasLength(3));
      expect(await kostoma.pendingCount(), 0);

      final dropped = events.where((event) => event.dropped).single;
      expect(dropped.statusCode, 422);
      expect(dropped.error?.code, 'invalid_request');
      expect(dropped.error?.details, {
        '/name': ['The property name is too long'],
      });
      expect(dropped.call?.type, KostomaCallType.track);
      expect(bodyOf(requests.last)['name'], 'login');
    });

    test('what is logged holds nothing personal', () async {
      final events = <KostomaLogEvent>[];
      final kostoma = build(
        client: recording([], (request, attempt) {
          return apiError(401, 'unauthenticated');
        }),
        events: events,
      );

      await kostoma.identify('u_secret', email: 'ada@example.com');
      await kostoma.flush();

      expect(events, isNotEmpty);
      for (final event in events) {
        expect(event.toString(), isNot(contains('u_secret')));
        expect(event.toString(), isNot(contains('ada@example.com')));
        expect(event.toString(), isNot(contains('kst_test_key')));
      }
    });

    test('a value that is not JSON is reported and nothing throws', () async {
      final requests = <http.Request>[];
      final events = <KostomaLogEvent>[];
      final kostoma = build(client: recording(requests), events: events);

      await kostoma.identify('u_1');
      await kostoma.track('login', data: {'when': Object()});
      await kostoma.flush();

      expect(pathsOf(requests), ['/api/v1/identify']);
      expect(
        events.where((event) => event.level == KostomaLogLevel.error),
        hasLength(1),
      );
    });
  });

  group('reset', () {
    test('removes the device and forgets the person', () async {
      final requests = <http.Request>[];
      final store = InMemoryKostomaStore();
      final kostoma = build(client: recording(requests), store: store);

      await kostoma.identify('u_1');
      await kostoma.registerDevice(
        'tok_1',
        platform: KostomaDevicePlatform.android,
      );
      await kostoma.flush();
      expect(requests, hasLength(2));

      await kostoma.reset();
      await kostoma.flush();

      expect(requests, hasLength(3));
      expect(requests.last.method, 'DELETE');
      expect(requests.last.url.path, '/api/v1/devices');
      expect(bodyOf(requests.last), {'token': 'tok_1'});
      expect(await kostoma.currentPersonId(), isNull);
      expect(store.snapshot().values.join(), isNot(contains('u_1')));
    });

    test('the next person gets the events and the device after it', () async {
      final requests = <http.Request>[];
      final kostoma = build(client: recording(requests));

      await kostoma.identify('u_1');
      await kostoma.registerDevice(
        'tok_1',
        platform: KostomaDevicePlatform.android,
      );
      await kostoma.reset();
      await kostoma.flush();
      requests.clear();

      await kostoma.track('app_opened');
      await kostoma.flush();
      expect(requests, isEmpty);

      await kostoma.identify('u_2');
      await kostoma.flush();

      expect(pathsOf(requests), [
        '/api/v1/identify',
        '/api/v1/track',
        '/api/v1/devices',
      ]);
      expect(requests.last.method, 'POST');
      for (final request in requests) {
        expect(bodyOf(request)['id'], 'u_2');
      }
      expect(bodyOf(requests.last)['token'], 'tok_1');
    });

    test('with no device registered sends nothing', () async {
      final requests = <http.Request>[];
      final kostoma = build(client: recording(requests));

      await kostoma.identify('u_1');
      await kostoma.flush();
      await kostoma.reset();
      await kostoma.flush();

      expect(pathsOf(requests), ['/api/v1/identify']);
      expect(await kostoma.currentPersonId(), isNull);
    });
  });

  group('devices', () {
    test('a new token replaces the old one', () async {
      final requests = <http.Request>[];
      final kostoma = build(client: recording(requests));

      await kostoma.identify('u_1');
      await kostoma.registerDevice(
        'tok_old',
        platform: KostomaDevicePlatform.ios,
      );
      await kostoma.registerDevice(
        'tok_new',
        platform: KostomaDevicePlatform.ios,
      );
      await kostoma.flush();

      expect(
        [for (final request in requests.skip(1)) request.method],
        ['POST', 'DELETE', 'POST'],
      );
      expect(bodyOf(requests[2]), {'token': 'tok_old'});
      expect(bodyOf(requests[3])['token'], 'tok_new');
    });
  });

  group('the shared instance', () {
    test('initialize makes the instance', () async {
      final requests = <http.Request>[];
      final created = Kostoma.initialize(
        apiKey: 'kst_test_key',
        baseUrl: baseUrl,
        httpClient: recording(requests),
        store: InMemoryKostomaStore(),
        logger: (event) {},
      );
      addTearDown(created.close);

      expect(Kostoma.isInitialized, isTrue);
      expect(Kostoma.instance, same(created));

      await Kostoma.instance.identify('u_1');
      await Kostoma.instance.flush();

      expect(pathsOf(requests), ['/api/v1/identify']);
    });
  });
}
