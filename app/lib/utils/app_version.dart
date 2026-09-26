import 'package:package_info_plus/package_info_plus.dart';

/// Lightweight container for the running app's version info.
class AppVersion {
  AppVersion({required this.version, required this.buildNumber});

  /// `pubspec.yaml` 中的 version name，例如 `0.1.0`。
  final String version;

  /// `pubspec.yaml` 中的 build number，例如 `1`。
  final String buildNumber;

  String get label => 'v$version（build $buildNumber）';

  static Future<AppVersion> load() async {
    final info = await PackageInfo.fromPlatform();
    return AppVersion(version: info.version, buildNumber: info.buildNumber);
  }
}
