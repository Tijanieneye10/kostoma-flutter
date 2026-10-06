/// The platforms Kostoma accepts a push token for.
enum KostomaDevicePlatform {
  ios('ios'),
  android('android');

  const KostomaDevicePlatform(this.value);

  /// The name the API uses for this platform.
  final String value;

  /// The platform with this API name, or null when there is none.
  static KostomaDevicePlatform? tryParse(Object? value) {
    for (final platform in KostomaDevicePlatform.values) {
      if (platform.value == value) {
        return platform;
      }
    }
    return null;
  }
}
