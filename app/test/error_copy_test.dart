import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/api/wenxiang_api.dart';
import 'package:wenxiang/copy/errors.dart';

void main() {
  test('keeps short Chinese API messages', () {
    expect(humanizeError(ApiException('无法连接问象服务（HTTP 503）')), '无法连接问象服务（HTTP 503）');
  });

  test('maps TLS handshake failures to a tunnel hint', () {
    expect(
      humanizeError('HandshakeException: Connection terminated during handshake'),
      contains('隧道'),
    );
    expect(
      humanizeError('HandshakeException: Connection terminated during handshake'),
      isNot(contains('局域网')),
    );
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
    expect(
      humanizeError(ApiException('spawn git ENOENT')),
      contains('Git'),
    );
  });

  test('keeps long Chinese git errors instead of rewriting them as re-login', () {
    const zh =
        '无法访问该仓库：GitHub 返回 403。常见原因：仓库为私有且当前登录无权克隆、OAuth 未授予 repo 权限，或组织启用了 SSO 但尚未授权问象。请在 GitHub 授权中勾选 repo，并完成组织 SSO 授权后重试。';
    expect(humanizeError(ApiException(zh)), zh);
    expect(humanizeError(ApiException(zh)), isNot(contains('重新打开 GitHub')));
  });

  test('maps leftover dest and missing-repo git fatals to short Chinese', () {
    expect(
      humanizeError(ApiException(
        "fatal: destination path '/home/fei/问象/octo/demo' already exists and is not an empty directory",
      )),
      matches(RegExp(r'目录|不完整|克隆')),
    );
    expect(
      humanizeError(ApiException("fatal: repository 'https://github.com/acme/nope.git/' not found")),
      matches(RegExp(r'找不到|仓库|克隆')),
    );
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

  test('maps stale ACP sessions after companion restart', () {
    expect(humanizeError(ApiException('Session not found')), contains('会话'));
  });

  test('never returns empty copy', () {
    expect(humanizeError(''), isNot(isEmpty));
  });
}
