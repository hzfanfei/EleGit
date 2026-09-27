import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/models.dart';
import 'package:wenxiang/screens/static_files_page.dart';
import 'package:wenxiang/theme.dart';

import 'support/fake_api.dart';

ThemeData _theme() => wenxiangTheme().copyWith(splashFactory: NoSplash.splashFactory);

class _FilesApi extends FakeWenxiangApi {
  _FilesApi(this.files);

  List<StaticFileItem> files;
  final deleted = <String>[];

  @override
  Future<StaticLibrary> listStaticFiles() async {
    return StaticLibrary(dir: r'C:\static', files: List<StaticFileItem>.of(files));
  }

  @override
  Future<void> deleteStaticFile(String path) async {
    deleted.add(path);
    files = files.where((file) => file.path != path).toList();
  }
}

StaticFileItem _file(String name) {
  return StaticFileItem(
    path: name,
    name: name,
    size: 2048,
    downloadUrl: 'https://example.test/$name',
  );
}

Future<void> _open(WidgetTester tester, _FilesApi api) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: _theme(),
      home: StaticFilesPage(api: api, onBack: () {}),
    ),
  );
  await tester.pump();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('select all deletes every resource after confirm', (tester) async {
    final api = _FilesApi([_file('a.apk'), _file('b.png')]);
    await _open(tester, api);

    expect(find.text('全选'), findsOneWidget);
    expect(find.text('a.apk'), findsOneWidget);
    expect(find.text('b.png'), findsOneWidget);

    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();
    expect(find.text('删除 2'), findsOneWidget);

    await tester.tap(find.text('删除 2'));
    await tester.pumpAndSettle();
    expect(find.text('删除全部 2 个资源？'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, '删除'));
    await tester.pumpAndSettle();

    expect(api.deleted, ['a.apk', 'b.png']);
    expect(find.text('还没有静态资源'), findsOneWidget);
    expect(find.text('已删除 2 个资源'), findsOneWidget);
  });

  testWidgets('unchecking one file deletes only the rest', (tester) async {
    final api = _FilesApi([_file('a.apk'), _file('b.png')]);
    await _open(tester, api);

    await tester.tap(find.text('全选'));
    await tester.pump();
    await tester.tap(find.byType(Checkbox).at(2));
    await tester.pump();
    expect(find.text('删除 1'), findsOneWidget);

    await tester.tap(find.text('删除 1'));
    await tester.pumpAndSettle();
    expect(find.text('删除选中的 1 个资源？'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, '删除'));
    await tester.pumpAndSettle();

    expect(api.deleted, ['a.apk']);
    expect(find.text('b.png'), findsOneWidget);
    expect(find.text('a.apk'), findsNothing);
  });

  testWidgets('the second line of a resource is its time', (tester) async {
    final api = _FilesApi([
      StaticFileItem(
        path: 'builds/问象.apk',
        name: '问象.apk',
        size: 2048,
        downloadUrl: 'https://example.test/a',
        mtime: '2026-09-27T14:59:00.000Z',
      ),
    ]);
    await _open(tester, api);

    final local = DateTime.parse('2026-09-27T14:59:00.000Z').toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    final when = '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
    expect(find.text('问象.apk'), findsOneWidget);
    expect(find.text(when), findsOneWidget);
    expect(find.textContaining('builds/'), findsNothing);
    expect(find.textContaining('KB'), findsNothing);
  });
}
