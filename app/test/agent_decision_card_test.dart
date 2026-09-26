import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/models.dart';
import 'package:wenxiang/theme.dart';
import 'package:wenxiang/widgets/agent_decision_card.dart';

void main() {
  testWidgets('choices stay folded until opened', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: Scaffold(
          body: AgentDecisionCard(
            event: ChatStreamEvent(
              type: 'ask',
              payload: {
                'requestId': 'q1',
                'title': '先定范围',
                'questions': [
                  {
                    'id': 'scope',
                    'prompt': '看哪一块？',
                    'options': [
                      {'id': 'login', 'label': '登录'},
                    ],
                  },
                ],
              },
            ),
            onSubmit: ({
              required String kind,
              required bool skip,
              required bool accept,
              required List<Map<String, dynamic>> answers,
            }) async {},
          ),
        ),
      ),
    );

    expect(find.text('先定范围'), findsOneWidget);
    expect(find.text('登录'), findsNothing);
    expect(find.text('确定'), findsNothing);

    await tester.tap(find.byKey(const Key('wx-decision-toggle')));
    await tester.pump();

    expect(find.text('登录'), findsOneWidget);
    expect(find.text('确定'), findsOneWidget);
    expect(find.text('收起'), findsOneWidget);
  });
}
