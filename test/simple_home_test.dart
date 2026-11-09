// 단순 문서 목록 화면 회귀 테스트.
// [작동원리] 실제 폴더를 만들어 scanDocuments가 문서 확장자만 모으고
// 숨김/Android 폴더는 건너뛰는지, 시작 라우트가 단순 목록인지 검사한다.
import 'dart:io';

import 'package:fadocx/features/simple/simple_documents_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('문서 확장자만 목록에 포함된다', () {
    final d = Directory.systemTemp.createTempSync('simple_scan');
    addTearDown(() => d.deleteSync(recursive: true));
    for (final n in ['a.hwp', 'b.HWPX', 'c.pdf', 'd.docx', 'e.xlsx', 'f.pptx', 'x.jpg', 'y.mp3']) {
      File('${d.path}/$n').writeAsStringSync('x');
    }
    Directory('${d.path}/.hidden').createSync();
    File('${d.path}/.hidden/z.pdf').writeAsStringSync('x');
    Directory('${d.path}/Android').createSync();
    File('${d.path}/Android/w.pdf').writeAsStringSync('x');
    Directory('${d.path}/sub').createSync();
    File('${d.path}/sub/g.doc').writeAsStringSync('x');

    final names = scanDocuments([d.path]).map((m) => m['name']).toSet();
    expect(names, {'a.hwp', 'b.HWPX', 'c.pdf', 'd.docx', 'e.xlsx', 'f.pptx', 'g.doc'});
  });

  test('시작 화면은 단순 문서 목록이다', () {
    final router = File('lib/config/routing/app_router.dart').readAsStringSync();
    expect(router, contains('SimpleDocumentsScreen()'));
    expect(router, isNot(contains('const MainShell()')));
  });

  test('폴더 선택 기능과 한글 문구가 있다', () {
    final src = File('lib/features/simple/simple_documents_screen.dart').readAsStringSync();
    expect(src, contains('FilePicker.getDirectoryPath'));
    expect(src, contains('폴더 선택'));
    final pdf = File('lib/features/viewer/presentation/widgets/modern_pdf_viewer.dart').readAsStringSync();
    expect(pdf, isNot(contains("'Search in PDF'")));
  });

  test('앱 이름이 문서 뷰어로 바뀌었다', () {
    final g = File('android/app/build.gradle.kts').readAsStringSync();
    expect(g, contains('manifestPlaceholders["appName"] = "문서 뷰어"'));
  });

  test('정렬과 즐겨찾기 기능이 있다', () {
    final src = File('lib/features/simple/simple_documents_screen.dart').readAsStringSync();
    expect(src, contains('_toggleFav'));
    expect(src, contains('이름순'));
    expect(src, contains("'★'"));
  });
}
