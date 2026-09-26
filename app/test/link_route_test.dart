import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/api/link_route.dart';

void main() {
  test('private and loopback addresses are 局域网', () {
    expect(linkRouteLabel('http://192.168.1.8:8787'), '局域网');
    expect(linkRouteLabel('http://10.0.0.4:8787/'), '局域网');
    expect(linkRouteLabel('http://172.16.0.2:8787'), '局域网');
    expect(linkRouteLabel('http://127.0.0.1:8787'), '局域网');
    expect(linkRouteLabel('http://localhost:8787'), '局域网');
  });

  test('public tunnel addresses are 穿透', () {
    expect(linkRouteLabel('https://wenxiang.ngrok.app'), '穿透');
    expect(linkRouteLabel('https://example.com:8787'), '穿透');
    expect(isLanBaseUrl('http://172.32.0.1:8787'), isFalse);
    expect(isLanBaseUrl('http://11.0.0.1:8787'), isFalse);
  });

  test('pickLanBase keeps the first reachable private url', () {
    final picked = pickLanBase(
      const [
        'https://wenxiang.ngrok.app',
        'http://10.0.0.1:8787/',
        'http://192.168.1.8:8787',
      ],
      reachable: (url) => url.contains('192.168'),
    );
    expect(picked, 'http://192.168.1.8:8787');
  });
}
