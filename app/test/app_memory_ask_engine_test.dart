import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenxiang/copy/ask_engine.dart';
import 'package:wenxiang/persist/app_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('legacy askEngine key makes both scopes explicit', () async {
    SharedPreferences.setMockInitialValues({AppMemory.askEngineKey: 'cursor'});
    final memory = AppMemory(await SharedPreferences.getInstance());
    expect(memory.askEngineBookIsExplicit(), isTrue);
    expect(memory.askEngineRepoIsExplicit(), isTrue);
    expect(memory.askEngineBook(), AskEngineChoice.cursor);
  });

  test('split keys only mark their scope explicit', () async {
    SharedPreferences.setMockInitialValues({
      AppMemory.askEngineBookKey: 'cursor',
      AppMemory.askEngineRepoKey: 'claude',
    });
    final memory = AppMemory(await SharedPreferences.getInstance());
    expect(memory.askEngineBookIsExplicit(), isTrue);
    expect(memory.askEngineRepoIsExplicit(), isTrue);
    expect(memory.askEngineRepo(), AskEngineChoice.claude);
  });

  test('empty prefs are not explicit until user saves', () async {
    SharedPreferences.setMockInitialValues({});
    final memory = AppMemory(await SharedPreferences.getInstance());
    expect(memory.askEngineBookIsExplicit(), isFalse);
    expect(memory.askEngineRepoIsExplicit(), isFalse);
    expect(memory.askEngineBook(), kDefaultAskEngine);
  });
}
