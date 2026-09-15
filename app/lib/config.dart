import 'generated/env_defaults.dart';

class AppEnv {
  static const publicUrl = String.fromEnvironment(
    'WENXIANG_PUBLIC_URL',
    defaultValue: kDefaultPublicUrl,
  );
  static const apiKey = String.fromEnvironment(
    'WENXIANG_API_KEY',
    defaultValue: kDefaultApiKey,
  );
}
