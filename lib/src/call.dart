/// The API calls the SDK makes.
enum KostomaCallType {
  identify('POST', 'identify'),
  track('POST', 'track'),
  registerDevice('POST', 'devices'),
  removeDevice('DELETE', 'devices');

  const KostomaCallType(this.method, this.path);

  /// The HTTP method of the call.
  final String method;

  /// The path of the call under `/api/v1/`.
  final String path;

  /// The call type with this name, or null when there is none.
  static KostomaCallType? tryParse(Object? name) {
    for (final type in KostomaCallType.values) {
      if (type.name == name) {
        return type;
      }
    }
    return null;
  }
}

/// One API call waiting in the queue.
///
/// [body] is what is sent, so it can hold personal data. It is given to the
/// logger callback with a dropped call and is never printed by the SDK.
class KostomaCall {
  const KostomaCall({
    required this.id,
    required this.type,
    required this.body,
    required this.queuedAt,
  });

  /// The SDK's own identifier for the call. It is not sent.
  final String id;

  final KostomaCallType type;

  /// The JSON body of the request.
  final Map<String, Object?> body;

  /// When the app made the call.
  final DateTime queuedAt;

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'type': type.name,
      'body': body,
      'queued_at': queuedAt.millisecondsSinceEpoch,
    };
  }

  /// The call saved by [toJson], or null when [json] is not one.
  static KostomaCall? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final id = json['id'];
    final type = KostomaCallType.tryParse(json['type']);
    final body = json['body'];
    final queuedAt = json['queued_at'];
    if (id is! String || type == null || body is! Map || queuedAt is! int) {
      return null;
    }
    return KostomaCall(
      id: id,
      type: type,
      body: Map<String, Object?>.from(body),
      queuedAt: DateTime.fromMillisecondsSinceEpoch(queuedAt, isUtc: true),
    );
  }
}
