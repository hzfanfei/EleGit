import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/api/wenxiang_api.dart';
import 'package:wenxiang/models.dart';

void main() {
  test('retries a dropped chat across a short tunnel reconnect', () {
    expect(
      shouldRetryChatStreamBeforeText(
        sawText: false,
        failures: 1,
        cancelled: false,
        error: Exception('connection closed'),
      ),
      isTrue,
    );
    expect(chatStreamRetryDelay(1), const Duration(seconds: 2));
    expect(chatStreamRetryDelay(2), const Duration(seconds: 4));
    expect(chatStreamRetryDelay(3), const Duration(seconds: 6));
    expect(
      shouldRetryChatStreamBeforeText(
        sawText: false,
        failures: 3,
        cancelled: false,
        error: Exception('connection closed'),
      ),
      isTrue,
    );
    expect(
      shouldRetryChatStreamBeforeText(
        sawText: false,
        failures: 4,
        cancelled: false,
        error: Exception('connection closed'),
      ),
      isFalse,
    );
  });

  test('keeps a partial answer instead of sending the question again', () {
    expect(
      shouldRetryChatStreamBeforeText(
        sawText: true,
        failures: 1,
        cancelled: false,
        error: Exception('connection closed'),
      ),
      isFalse,
    );
    expect(
      chatEventHasVisibleText(ChatStreamEvent(type: 'delta', text: '你好')),
      isTrue,
    );
    expect(
      chatEventHasVisibleText(ChatStreamEvent(type: 'start', text: '')),
      isFalse,
    );
    expect(
      chatEventHasVisibleText(ChatStreamEvent(type: 'caption', text: '已经开口')),
      isTrue,
    );
  });

  test('does not retry a server error or a cancel', () {
    expect(
      shouldRetryChatStreamBeforeText(
        sawText: false,
        failures: 1,
        cancelled: false,
        error: ApiException('问答失败'),
      ),
      isFalse,
    );
    expect(
      shouldRetryChatStreamBeforeText(
        sawText: false,
        failures: 1,
        cancelled: true,
        error: Exception('connection closed'),
      ),
      isFalse,
    );
    expect(
      shouldRetryChatStreamBeforeText(
        sawText: false,
        failures: 1,
        cancelled: false,
        error: const OperationCancelled(),
      ),
      isFalse,
    );
  });
}
