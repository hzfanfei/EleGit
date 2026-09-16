import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/api/wenxiang_api.dart';
import 'package:wenxiang/copy/errors.dart';

void main() {
  test('keeps short Chinese API messages', () {
    expect(humanizeError(ApiException('无法连接问象服务（HTTP 503）')), '无法连接问象服务（HTTP 503）');
  });

  test('maps network failures to a reconnect hint', () {
    const raw = 'SocketException: Connection refused (OS Error: Connection refused, errno = 111)';
    expect(humanizeError(raw), contains('连不上本机问象服务'));
    expect(humanizeError(raw), isNot(contains('SocketException')));
  });

  test('maps auth failures without leaking stacks', () {
    expect(humanizeError('Exception: HTTP 401 Unauthorized'), contains('授权'));
    expect(humanizeError('Exception: HTTP 401 Unauthorized'), isNot(contains('Exception')));
  });

  test('maps clone failures', () {
    expect(humanizeError(ApiException('git clone failed: Authentication failed')), contains('克隆'));
  });

  test('maps SSE drops without leaking stacks', () {
    expect(
      humanizeError(ApiException('ClientException: Connection closed before full headers were received')),
      contains('连接中断'),
    );
    expect(
      humanizeError(ApiException('ClientException: Connection closed before full headers were received')),
      isNot(contains('ClientException')),
    );
  });

  test('never returns empty copy', () {
    expect(humanizeError(''), isNot(isEmpty));
  });
}
