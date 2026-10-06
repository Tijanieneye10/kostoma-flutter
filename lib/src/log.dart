import 'dart:convert';

import 'call.dart';

/// How serious a [KostomaLogEvent] is.
enum KostomaLogLevel { debug, warning, error }

/// Receives what the SDK has to report.
typedef KostomaLogger = void Function(KostomaLogEvent event);

/// An error answered by the Kostoma API.
class KostomaApiError {
  const KostomaApiError({
    required this.code,
    required this.message,
    this.details = const {},
  });

  /// A stable name for the kind of error, such as `invalid_request`.
  final String code;

  /// What went wrong and how to fix it.
  final String message;

  /// For `invalid_request`: the problems found, keyed by the field's path in
  /// the body.
  final Map<String, List<String>> details;

  /// The error in a response body, or null when the body is not one.
  static KostomaApiError? tryParse(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        return null;
      }
      final error = decoded['error'];
      if (error is! Map) {
        return null;
      }
      final code = error['code'];
      final message = error['message'];
      if (code is! String || message is! String) {
        return null;
      }
      final details = <String, List<String>>{};
      final rawDetails = error['details'];
      if (rawDetails is Map) {
        for (final entry in rawDetails.entries) {
          final key = entry.key;
          final value = entry.value;
          if (key is String && value is List) {
            details[key] = value.whereType<String>().toList();
          }
        }
      }
      return KostomaApiError(code: code, message: message, details: details);
    } catch (_) {
      return null;
    }
  }

  @override
  String toString() => '$code: $message';
}

/// Something the SDK reports: a call that was dropped, a retry, a problem
/// with storage.
///
/// [message] and [toString] never contain personal data. [call] and [error]
/// can, so think before writing them to a log.
class KostomaLogEvent {
  const KostomaLogEvent({
    required this.level,
    required this.message,
    this.call,
    this.statusCode,
    this.error,
    this.retryIn,
    this.dropped = false,
  });

  final KostomaLogLevel level;

  /// What happened, without personal data.
  final String message;

  /// The call this is about, when it is about one.
  final KostomaCall? call;

  /// The HTTP status the API answered with, when it answered.
  final int? statusCode;

  /// The error the API answered with, when it sent one.
  final KostomaApiError? error;

  /// How long the SDK waits before it tries the call again.
  final Duration? retryIn;

  /// Whether a call was thrown away and will not be sent.
  final bool dropped;

  @override
  String toString() => 'kostoma ${level.name}: $message';
}
