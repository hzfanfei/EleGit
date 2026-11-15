import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/api/wenxiang_api.dart';
import 'package:wenxiang/models.dart';
import 'package:wenxiang/screens/temporary_chat_page.dart';

class TemporaryApi extends WenxiangApi {
  TemporaryApi() : super(baseUrl: 'http://localhost', apiKey: 'test');
  int created = 0;
  final closed = <String>[];
  final sent = <String>[];
  String? lastModel;

  @override
  Future<Map<String, dynamic>> codexModels() async => {
    'models': [{'id': 'model-a', 'label': 'Model A'}],
  };

  @override
  Future<String> createTemporaryChat() async => 'temp-${++created}';
  @override
  Future<void> closeTemporaryChat(String id) async { closed.add(id); }
  @override
  Future<void> pingTemporaryChat(String id) async {}
  @override
  Stream<ChatStreamEvent> temporaryChatStream(String id, String message, {String? model}) async* {
    lastModel = model;
    sent.add('$id:$message');
    yield ChatStreamEvent(type: 'delta', text: '这是回答');
    yield ChatStreamEvent(type: 'done');
  }
}


void main() {
  testWidgets('退出后清除当前消息，重新进入创建新会话', (tester) async {
    final api = TemporaryApi();
    var visible = true;
    late StateSetter update;
    await tester.pumpWidget(MaterialApp(home: StatefulBuilder(builder: (context, setState) {
      update = setState;
      return visible
          ? TemporaryChatPage(api: api, onBack: () => setState(() => visible = false))
          : const Scaffold(body: Text('首页'));
    })));
    await tester.pump();
    expect(find.text('临时会话'), findsOneWidget);
    await tester.tap(find.text('选择模型'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Model A'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('按住说话'));
    await tester.pumpAndSettle();
    expect(find.text('按住 说话'), findsOneWidget);
    await tester.tap(find.byTooltip('键盘输入'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '你好');
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    expect(api.sent, ['temp-1:你好']);
    expect(api.lastModel, 'model-a');
    expect(find.text('这是回答'), findsOneWidget);
    update(() => visible = false);
    await tester.pumpAndSettle();
    expect(api.closed, ['temp-1']);
    update(() => visible = true);
    await tester.pumpAndSettle();
    expect(api.created, 2);
    expect(find.text('这是回答'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
