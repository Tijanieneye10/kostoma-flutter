import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kostoma/kostoma.dart';

/// 2026-09-29T18:09:52Z, which is 1790705392 in Unix seconds.
final DateTime now = DateTime.utc(2026, 9, 29, 18, 9, 52);

/// What this version of the SDK puts on the wire, call by call.
///
/// `compat/requests.json` is the record of it. A copy of that file, for
/// every released version, is kept in the Kostoma repository, where a test
/// sends each request to the real API. That is how a change to the API is
/// stopped from breaking an SDK version somebody has already installed.
///
/// If this test fails, the SDK now sends something different. That is a
/// change for everyone who upgrades, so: bump the version, update
/// `compat/requests.json` to match, and follow RELEASING.md.
void main() {
  test('requests match the record for this version', () async {
    final file = File('compat/requests.json').readAsStringSync();
    final recorded = jsonDecode(file) as Map<String, dynamic>;

    final requests = <http.Request>[];
    final kostoma = Kostoma(
      apiKey: 'kst_test_key',
      baseUrl: Uri.parse('https://kostoma.example.com'),
      httpClient: MockClient((request) async {
        requests.add(request);
        return http.Response('{"status":"accepted"}', 202);
      }),
      store: InMemoryKostomaStore(),
      logger: (_) {},
      clock: () => now,
    );
    addTearDown(kostoma.close);

    await kostoma.identify(
      'u_1042',
      email: 'ada@example.com',
      attributes: {
        'first_name': 'Ada',
        'kyc_level': 2,
        'is_verified': true,
        'signed_up_at': now,
      },
    );
    await kostoma.track(
      'transfer_completed',
      data: {'amount': 25000, 'currency': 'NGN'},
    );
    await kostoma.registerDevice(
      'fcm-token-1',
      platform: KostomaDevicePlatform.android,
    );
    await kostoma.reset();

    for (var i = 0; i < 50 && await kostoma.pendingCount() > 0; i++) {
      await kostoma.flush();
    }

    final sent = [
      for (final request in requests)
        {
          'method': request.method,
          'path': request.url.path,
          'body': _withoutRandomParts(
            Map<String, dynamic>.from(jsonDecode(request.body) as Map),
          ),
        },
    ];

    final expected = [
      for (final request in recorded['requests'] as List)
        {
          'method': (request as Map)['method'],
          'path': request['path'],
          'body': request['body'],
        },
    ];

    expect(recorded['version'], kostomaSdkVersion);
    expect(sent, expected);

    for (final request in requests) {
      expect(request.headers['X-Kostoma-Sdk'], 'flutter/$kostomaSdkVersion');
      expect(request.headers['Authorization'], 'Bearer kst_test_key');
    }
  });
}

/// The event id is random, so the record holds a placeholder for it.
Map<String, dynamic> _withoutRandomParts(Map<String, dynamic> body) {
  final eventId = body['event_id'];
  if (eventId != null) {
    expect(eventId, matches(RegExp(r'^[0-9a-f]{32}$')));
    body['event_id'] = '<event_id>';
  }
  return body;
}
