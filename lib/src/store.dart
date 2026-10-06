import 'package:shared_preferences/shared_preferences.dart';

/// Where the SDK keeps its queue and the current person between app starts.
abstract class KostomaStore {
  /// The value saved under [key], or null when there is none.
  Future<String?> read(String key);

  /// Save [value] under [key], replacing what was there.
  Future<void> write(String key, String value);

  /// Forget what is saved under [key].
  Future<void> delete(String key);
}

/// Keeps everything in memory. For tests, and for apps that want nothing
/// written to the device.
class InMemoryKostomaStore implements KostomaStore {
  final Map<String, String> _values = {};

  /// A copy of everything saved.
  Map<String, String> snapshot() => Map<String, String>.of(_values);

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }
}

/// Keeps everything in the app's shared preferences. The default.
class SharedPreferencesKostomaStore implements KostomaStore {
  @override
  Future<String?> read(String key) async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(key);
  }

  @override
  Future<void> write(String key, String value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(key, value);
  }

  @override
  Future<void> delete(String key) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(key);
  }
}
