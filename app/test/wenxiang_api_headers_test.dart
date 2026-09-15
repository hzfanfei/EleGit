import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/api/wenxiang_api.dart';

void main() {
  test('HTTP headers include API key and ngrok skip warning', () {
    final api = WenxiangApi(
      baseUrl: 'https://nonstrategically-pulverable-libby.ngrok-free.dev',
      apiKey: 'test-key',
    );
    expect(api.headers['X-Wenxiang-Key'], 'test-key');
    expect(api.headers['ngrok-skip-browser-warning'], 'true');
  });
}
