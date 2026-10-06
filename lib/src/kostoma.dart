import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'call.dart';
import 'log.dart';
import 'platform.dart';
import 'store.dart';
import 'version.dart';

/// Sends people, events and devices from a Flutter app to Kostoma.
///
/// Every call is added to a queue saved on the device and sent in order, so
/// nothing here throws for network trouble or waits on the network. The
/// future each method returns completes when the call is saved, not when it
/// is sent.
///
/// Use [Kostoma.initialize] once at startup and [Kostoma.instance] after
/// that, or make your own with the constructor.
class Kostoma {
  /// Make a client. Give it a data-only API key and the address of your
  /// Kostoma, such as `Uri.parse('https://kostoma.example.com')`.
  ///
  /// [logger] is told about calls that were dropped and about retries. With
  /// none, warnings and errors are printed in debug builds only, without
  /// personal data.
  Kostoma({
    required String apiKey,
    required Uri baseUrl,
    http.Client? httpClient,
    KostomaStore? store,
    KostomaLogger? logger,
    this.maxQueueSize = 1000,
    this.requestTimeout = const Duration(seconds: 30),
    this.initialBackoff = const Duration(seconds: 2),
    this.maxBackoff = const Duration(minutes: 5),
    DateTime Function()? clock,
  })  : assert(maxQueueSize > 0),
        _apiKey = apiKey,
        _baseUrl = baseUrl,
        _http = httpClient ?? http.Client(),
        _ownsHttp = httpClient == null,
        _store = store ?? SharedPreferencesKostomaStore(),
        _logger = logger ?? _defaultLogger,
        _clock = clock ?? DateTime.now {
    _tail = _load();
  }

  static const String _queueKey = 'kostoma.queue';
  static const String _stateKey = 'kostoma.state';
  static const int _maxRetryAfterSeconds = 3600;

  static Kostoma? _instance;

  /// The client made by [initialize].
  ///
  /// Throws a [StateError] when [initialize] has not been called.
  static Kostoma get instance {
    final current = _instance;
    if (current == null) {
      throw StateError('Call Kostoma.initialize before Kostoma.instance.');
    }
    return current;
  }

  /// Whether [initialize] has been called.
  static bool get isInitialized => _instance != null;

  /// Make the client [instance] returns. Call it once, at startup, after
  /// `WidgetsFlutterBinding.ensureInitialized()`.
  ///
  /// Calling it again closes the earlier client and replaces it.
  static Kostoma initialize({
    required String apiKey,
    required Uri baseUrl,
    http.Client? httpClient,
    KostomaStore? store,
    KostomaLogger? logger,
    int maxQueueSize = 1000,
    Duration requestTimeout = const Duration(seconds: 30),
    Duration initialBackoff = const Duration(seconds: 2),
    Duration maxBackoff = const Duration(minutes: 5),
  }) {
    _instance?.close();
    final created = Kostoma(
      apiKey: apiKey,
      baseUrl: baseUrl,
      httpClient: httpClient,
      store: store,
      logger: logger,
      maxQueueSize: maxQueueSize,
      requestTimeout: requestTimeout,
      initialBackoff: initialBackoff,
      maxBackoff: maxBackoff,
    );
    _instance = created;
    return created;
  }

  /// The most calls kept waiting. When one more arrives, the oldest is
  /// dropped.
  final int maxQueueSize;

  /// How long one request may take before it counts as a network error.
  final Duration requestTimeout;

  /// The wait after the first failed attempt. It doubles with each failure.
  final Duration initialBackoff;

  /// The longest wait between attempts.
  final Duration maxBackoff;

  final String _apiKey;
  final Uri _baseUrl;
  final http.Client _http;
  final bool _ownsHttp;
  final KostomaStore _store;
  final KostomaLogger _logger;
  final DateTime Function() _clock;
  final Random _random = _makeRandom();

  /// Calls waiting to be sent, oldest first.
  final List<KostomaCall> _queue = [];

  /// Events tracked while nobody was identified. They have no person yet.
  final List<KostomaCall> _held = [];

  String? _personId;
  _Device? _device;

  /// The last operation on the state. Each one runs after the one before it.
  Future<void> _tail = Future<void>.value();

  /// The last write to the store.
  Future<void> _writes = Future<void>.value();

  Future<void>? _draining;
  Timer? _retryTimer;
  int _failures = 0;
  bool _closed = false;

  /// Say who is using the app, and what you know about them.
  ///
  /// [id] is your own identifier for the person. It is remembered, on the
  /// device, as the current person until [reset]. [attributes] are merged
  /// into the ones Kostoma already has; one sent as null is removed. A
  /// [DateTime] among them is sent as Unix seconds.
  ///
  /// Events tracked before this call, and a device registered before it, are
  /// sent for this person straight after.
  Future<void> identify(
    String id, {
    String? email,
    Map<String, Object?> attributes = const {},
  }) {
    return _run(() async {
      if (id.isEmpty) {
        _log(KostomaLogLevel.error, 'identify ignored: the id is empty.');
        return;
      }
      final body = _plain(KostomaCallType.identify, {
        'id': id,
        if (email != null) 'email': email,
        if (attributes.isNotEmpty) 'attributes': attributes,
      });
      if (body == null) {
        return;
      }
      _personId = id;
      _enqueue(KostomaCallType.identify, body);
      for (final held in _held) {
        _enqueue(
          KostomaCallType.track,
          {'id': id, ...held.body},
          id: held.id,
          queuedAt: held.queuedAt,
        );
      }
      _held.clear();
      final device = _device;
      if (device != null && device.registeredFor != id) {
        _enqueue(KostomaCallType.registerDevice, _deviceBody(id, device));
        _device = device.registeredTo(id);
      }
      await _saveQueue();
      await _saveState();
      _kick();
    });
  }

  /// Record that the current person did something.
  ///
  /// The event is stamped with the time on the device now, or with
  /// [timestamp], so an event sent late is not recorded as happening late.
  /// A [DateTime] in [data] is sent as Unix seconds.
  ///
  /// The API has no anonymous people: an event needs a person. While nobody
  /// is identified, events are held on the device and sent, with their
  /// original times, after the next [identify].
  Future<void> track(
    String name, {
    Map<String, Object?> data = const {},
    DateTime? timestamp,
  }) {
    final happenedAt = timestamp ?? _clock();
    return _run(() async {
      if (name.isEmpty) {
        _log(KostomaLogLevel.error, 'track ignored: the name is empty.');
        return;
      }
      final body = _plain(KostomaCallType.track, {
        'name': name,
        if (data.isNotEmpty) 'data': data,
        'timestamp': _unixSeconds(happenedAt),
        'event_id': _newId(),
      });
      if (body == null) {
        return;
      }
      final person = _personId;
      if (person == null) {
        _held.add(
          KostomaCall(
            id: _newId(),
            type: KostomaCallType.track,
            body: body,
            queuedAt: happenedAt,
          ),
        );
        _trim(_held);
        await _saveState();
        return;
      }
      _enqueue(KostomaCallType.track, {'id': person, ...body});
      await _saveQueue();
      _kick();
    });
  }

  /// Store this device's push token for the current person.
  ///
  /// The token is remembered. While nobody is identified it is not sent; it
  /// is registered for whoever is identified next.
  Future<void> registerDevice(
    String token, {
    required KostomaDevicePlatform platform,
  }) {
    return _run(() async {
      if (token.isEmpty) {
        _log(
          KostomaLogLevel.error,
          'registerDevice ignored: the token is empty.',
        );
        return;
      }
      final previous = _device;
      if (previous != null &&
          previous.token != token &&
          previous.registeredFor != null) {
        // The token was replaced, so the old one is of no more use.
        _enqueue(KostomaCallType.removeDevice, {'token': previous.token});
      }
      final person = _personId;
      final device = _Device(token, platform, person);
      _device = device;
      if (person != null) {
        _enqueue(KostomaCallType.registerDevice, _deviceBody(person, device));
      }
      await _saveQueue();
      await _saveState();
      _kick();
    });
  }

  /// Make Kostoma forget a push token, so no push is sent to it.
  Future<void> removeDevice(String token) {
    return _run(() async {
      if (token.isEmpty) {
        _log(
          KostomaLogLevel.error,
          'removeDevice ignored: the token is empty.',
        );
        return;
      }
      _enqueue(KostomaCallType.removeDevice, {'token': token});
      if (_device?.token == token) {
        _device = null;
      }
      await _saveQueue();
      await _saveState();
      _kick();
    });
  }

  /// Call this when the person signs out.
  ///
  /// The device is removed from the person, so the next user of the phone
  /// does not get their pushes, and the current person is forgotten. Calls
  /// already waiting are still sent. The push token stays on the device,
  /// tied to nobody, and is registered for whoever is identified next.
  Future<void> reset() {
    return _run(() async {
      final device = _device;
      if (device != null && device.registeredFor != null) {
        _enqueue(KostomaCallType.removeDevice, {'token': device.token});
        _device = device.registeredTo(null);
      }
      _personId = null;
      await _saveQueue();
      await _saveState();
      _kick();
    });
  }

  /// Send whatever is waiting now, without waiting out a retry delay.
  ///
  /// Completes when the queue is empty or an attempt has failed.
  Future<void> flush() async {
    await _tail;
    if (_closed) {
      return;
    }
    _retryTimer?.cancel();
    _retryTimer = null;
    if (_queue.isEmpty) {
      return;
    }
    await _drain();
  }

  /// The id given to the last [identify], or null after [reset].
  Future<String?> currentPersonId() async {
    await _tail;
    return _personId;
  }

  /// How many calls are waiting to be sent. Events held until the next
  /// [identify] are not counted.
  Future<int> pendingCount() async {
    await _tail;
    return _queue.length;
  }

  /// Stop sending. What is waiting stays saved for the next client.
  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    if (_ownsHttp) {
      _http.close();
    }
  }

  static void _defaultLogger(KostomaLogEvent event) {
    if (kDebugMode && event.level != KostomaLogLevel.debug) {
      debugPrint(event.toString());
    }
  }

  static Random _makeRandom() {
    try {
      return Random.secure();
    } catch (_) {
      return Random();
    }
  }

  static int _unixSeconds(DateTime moment) {
    final seconds = moment.millisecondsSinceEpoch ~/ 1000;
    return seconds < 0 ? 0 : seconds;
  }

  static Object? _toEncodable(Object? value) {
    if (value is DateTime) {
      return _unixSeconds(value);
    }
    // What jsonEncode does by default.
    return (value as dynamic).toJson();
  }

  /// Run [operation] after every earlier one, so calls keep the order the
  /// app made them in. Nothing it throws reaches the app.
  Future<void> _run(Future<void> Function() operation) {
    final result = _tail.then((_) async {
      if (_closed) {
        return;
      }
      try {
        await operation();
      } catch (error) {
        _log(
          KostomaLogLevel.error,
          'A call could not be queued (${error.runtimeType}).',
        );
      }
    });
    _tail = result;
    return result;
  }

  Future<void> _load() async {
    try {
      final rawState = await _store.read(_stateKey);
      if (rawState != null) {
        final state = jsonDecode(rawState);
        if (state is Map) {
          final person = state['person_id'];
          if (person is String && person.isNotEmpty) {
            _personId = person;
          }
          _device = _Device.fromJson(state['device']);
          _held.addAll(_decodeCalls(state['held']));
        }
      }
      final rawQueue = await _store.read(_queueKey);
      if (rawQueue != null) {
        _queue.addAll(_decodeCalls(jsonDecode(rawQueue)));
      }
    } catch (error) {
      _log(
        KostomaLogLevel.error,
        'Saved state could not be read (${error.runtimeType}).',
      );
    }
    _kick();
  }

  List<KostomaCall> _decodeCalls(Object? json) {
    final calls = <KostomaCall>[];
    if (json is List) {
      for (final item in json) {
        final call = KostomaCall.fromJson(item);
        if (call != null) {
          calls.add(call);
        }
      }
    }
    return calls;
  }

  /// [body] as plain JSON values, or null when it cannot be sent as JSON.
  Map<String, Object?>? _plain(
    KostomaCallType type,
    Map<String, Object?> body,
  ) {
    try {
      final encoded = jsonEncode(body, toEncodable: _toEncodable);
      return Map<String, Object?>.from(jsonDecode(encoded) as Map);
    } catch (_) {
      _log(
        KostomaLogLevel.error,
        '${type.name} ignored: it holds a value that cannot be sent as JSON.',
      );
      return null;
    }
  }

  Map<String, Object?> _deviceBody(String personId, _Device device) {
    return {
      'id': personId,
      'token': device.token,
      'platform': device.platform.value,
      'last_used': _unixSeconds(_clock()),
    };
  }

  String _newId() {
    final buffer = StringBuffer();
    for (var i = 0; i < 16; i++) {
      buffer.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  void _enqueue(
    KostomaCallType type,
    Map<String, Object?> body, {
    String? id,
    DateTime? queuedAt,
  }) {
    _queue.add(
      KostomaCall(
        id: id ?? _newId(),
        type: type,
        body: body,
        queuedAt: queuedAt ?? _clock(),
      ),
    );
    _trim(_queue);
  }

  /// Drop the oldest of [calls] until no more than [maxQueueSize] are left.
  void _trim(List<KostomaCall> calls) {
    var dropped = 0;
    while (calls.length > maxQueueSize) {
      calls.removeAt(0);
      dropped += 1;
    }
    if (dropped > 0) {
      _log(
        KostomaLogLevel.warning,
        'The queue is full ($maxQueueSize calls): the oldest was dropped.',
        dropped: true,
      );
    }
  }

  Future<void> _saveQueue() {
    return _write(_queueKey, () {
      return jsonEncode([for (final call in _queue) call.toJson()]);
    });
  }

  Future<void> _saveState() {
    return _write(_stateKey, () {
      return jsonEncode({
        'person_id': _personId,
        'device': _device?.toJson(),
        'held': [for (final call in _held) call.toJson()],
      });
    });
  }

  /// Write to the store after every earlier write. [encode] runs when the
  /// write's turn comes, so the last write always holds the latest state.
  Future<void> _write(String key, String Function() encode) {
    final result = _writes.then((_) async {
      try {
        await _store.write(key, encode());
      } catch (error) {
        _log(
          KostomaLogLevel.error,
          'State could not be saved (${error.runtimeType}).',
        );
      }
    });
    _writes = result;
    return result;
  }

  /// Start sending, unless a send is running or a retry is being waited for.
  void _kick() {
    if (_closed || _retryTimer != null || _queue.isEmpty) {
      return;
    }
    unawaited(_drain());
  }

  Future<void> _drain() {
    return _draining ??= _drainLoop();
  }

  /// The one sender: takes calls from the front of the queue until it is
  /// empty or a call has to be tried again later.
  Future<void> _drainLoop() async {
    // Let _drain record this run before anything below can end it.
    await Future<void>.value();
    try {
      while (!_closed && _queue.isNotEmpty) {
        final call = _queue.first;
        final retryIn = await _send(call);
        if (_closed) {
          return;
        }
        if (retryIn != null) {
          _retryTimer?.cancel();
          _retryTimer = Timer(retryIn, () {
            _retryTimer = null;
            _kick();
          });
          return;
        }
        _queue.removeWhere((queued) => queued.id == call.id);
        await _saveQueue();
      }
    } catch (error) {
      _log(
        KostomaLogLevel.error,
        'Sending stopped unexpectedly (${error.runtimeType}).',
      );
    } finally {
      _draining = null;
    }
  }

  /// Send one call. Returns how long to wait before trying it again, or null
  /// when the queue can move on: the call was accepted, or it was refused in
  /// a way that trying again cannot fix.
  Future<Duration?> _send(KostomaCall call) async {
    final name = call.type.name;
    final response = await _attempt(call);

    if (response == null) {
      final retryIn = _nextBackoff();
      _log(
        KostomaLogLevel.debug,
        '$name not sent: the network failed. Trying again later.',
        call: call,
        retryIn: retryIn,
      );
      return retryIn;
    }

    final status = response.statusCode;

    if (status >= 200 && status < 300) {
      _failures = 0;
      _log(KostomaLogLevel.debug, '$name sent.', statusCode: status);
      return null;
    }

    final error = KostomaApiError.tryParse(
      utf8.decode(response.bodyBytes, allowMalformed: true),
    );
    final code = error == null ? '' : ' (${error.code})';

    if (status == 408 || status == 429 || status >= 500) {
      var retryIn = _nextBackoff();
      if (status == 429) {
        retryIn = _retryAfter(response) ?? retryIn;
      }
      _log(
        KostomaLogLevel.warning,
        '$name not sent: the API answered $status$code. Trying again later.',
        call: call,
        statusCode: status,
        error: error,
        retryIn: retryIn,
      );
      return retryIn;
    }

    _failures = 0;
    _log(
      KostomaLogLevel.error,
      '$name dropped: the API answered $status$code. It is not retried.',
      call: call,
      statusCode: status,
      error: error,
      dropped: true,
    );
    return null;
  }

  /// The API's answer to [call], or null when none arrived.
  Future<http.Response?> _attempt(KostomaCall call) async {
    try {
      final request = http.Request(call.type.method, _endpoint(call.type.path))
        ..headers['Authorization'] = 'Bearer $_apiKey'
        ..headers['Content-Type'] = 'application/json'
        ..headers['Accept'] = 'application/json'
        ..headers['X-Kostoma-Sdk'] = 'flutter/$kostomaSdkVersion'
        ..bodyBytes = utf8.encode(jsonEncode(call.body));
      final streamed = await _http.send(request).timeout(requestTimeout);
      return await http.Response.fromStream(streamed).timeout(requestTimeout);
    } catch (_) {
      return null;
    }
  }

  Uri _endpoint(String path) {
    var base = _baseUrl.path;
    if (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return _baseUrl.replace(path: '$base/api/v1/$path');
  }

  /// Count a failure and return the wait it earns: [initialBackoff], doubled
  /// for each failure in a row, up to [maxBackoff].
  Duration _nextBackoff() {
    _failures += 1;
    final doublings = _failures - 1 > 20 ? 20 : _failures - 1;
    final milliseconds = initialBackoff.inMilliseconds * (1 << doublings);
    if (milliseconds > maxBackoff.inMilliseconds) {
      return maxBackoff;
    }
    return Duration(milliseconds: milliseconds);
  }

  /// The seconds in a Retry-After header, or null when there is none.
  Duration? _retryAfter(http.Response response) {
    for (final header in response.headers.entries) {
      if (header.key.toLowerCase() == 'retry-after') {
        final seconds = int.tryParse(header.value.trim());
        if (seconds == null || seconds < 0) {
          return null;
        }
        return Duration(seconds: min(seconds, _maxRetryAfterSeconds));
      }
    }
    return null;
  }

  void _log(
    KostomaLogLevel level,
    String message, {
    KostomaCall? call,
    int? statusCode,
    KostomaApiError? error,
    Duration? retryIn,
    bool dropped = false,
  }) {
    try {
      _logger(
        KostomaLogEvent(
          level: level,
          message: message,
          call: call,
          statusCode: statusCode,
          error: error,
          retryIn: retryIn,
          dropped: dropped,
        ),
      );
    } catch (_) {
      // A logger that throws must not stop the queue.
    }
  }
}

/// The push token the app last registered, and who it is registered for.
class _Device {
  const _Device(this.token, this.platform, this.registeredFor);

  final String token;
  final KostomaDevicePlatform platform;

  /// The person Kostoma was told this device belongs to, or null when it has
  /// not been registered for anyone.
  final String? registeredFor;

  _Device registeredTo(String? personId) {
    return _Device(token, platform, personId);
  }

  Map<String, Object?> toJson() {
    return {
      'token': token,
      'platform': platform.value,
      'registered_for': registeredFor,
    };
  }

  static _Device? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final token = json['token'];
    final platform = KostomaDevicePlatform.tryParse(json['platform']);
    final registeredFor = json['registered_for'];
    if (token is! String || token.isEmpty || platform == null) {
      return null;
    }
    return _Device(
      token,
      platform,
      registeredFor is String ? registeredFor : null,
    );
  }
}
