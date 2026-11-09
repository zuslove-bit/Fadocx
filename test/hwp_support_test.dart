// HWP/HWPX 지원이 빠짐없이 연결되어 있는지 확인하는 회귀 테스트.
//
// [작동원리] 네이티브(Rust) 라이브러리 없이 돌아가도록, 소스·설정 파일을 읽어
// hwp/hwpx 관련 연결 지점이 존재하는지만 검사한다. (실제 렌더링은 기기에서 확인)
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('HWP/HWPX 연결 지점', () {
    test('pubspec에 flutter_rhwp 의존성이 있다', () {
      expect(_read('pubspec.yaml'), contains('flutter_rhwp:'));
    });

    test('AndroidManifest에 hwp/hwpx 경로 패턴과 MIME이 있다', () {
      final m = _read('android/app/src/main/AndroidManifest.xml');
      expect(m, contains(r'.*\\.hwp"'));
      expect(m, contains(r'.*\\.hwpx"'));
      expect(m, contains('application/x-hwp'));
      expect(m, contains('application/vnd.hancom.hwpx'));
    });

    test('MIME을 모르는 파일 관리자용 확장자 필터(content/file)가 있다', () {
      final m = _read('android/app/src/main/AndroidManifest.xml');
      expect(m, contains('android:mimeType="*/*"'));
      expect(m, contains(r'pathPattern=".*\\.hwp"'));
      expect(m, contains(r'pathPattern=".*\\..*\\.hwpx"'));
      expect(m, contains('application/hwp"'));
    });

    test('파일 선택기/탐색 목록 두 곳 모두 hwp, hwpx를 포함한다', () {
      final s = _read('lib/features/home/presentation/screens/browse_screen.dart');
      expect("'hwp',".allMatches(s).length, greaterThanOrEqualTo(2));
      expect("'hwpx',".allMatches(s).length, greaterThanOrEqualTo(2));
    });

    test('문서 파싱 분기가 hwp/hwpx를 처리한다', () {
      final s = _read(
          'lib/features/viewer/presentation/providers/document_viewer_notifier.dart');
      expect(s, contains("case 'hwp':"));
      expect(s, contains("case 'hwpx':"));
    });

    test('뷰어 화면이 HWP를 LibreOffice보다 먼저 HwpViewer로 보낸다', () {
      final s =
          _read('lib/features/viewer/presentation/screens/viewer_screen.dart');
      final hwp = s.indexOf("format == 'HWP'");
      final lokit = s.indexOf('return LOKitDocumentViewer(');
      expect(hwp, greaterThan(-1));
      expect(lokit, greaterThan(-1));
      expect(hwp, lessThan(lokit));
    });

    test('썸네일이 hwp를 텍스트 파서로 보내지 않는다', () {
      final s = _read('lib/core/services/thumbnail_generation_service.dart');
      // 텍스트 썸네일 그룹 줄에는 hwp가 없어야 한다(파싱 실패 방지).
      final textLine =
          s.split('\n').firstWhere((l) => l.contains('=> _generateTextThumbnail('));
      expect(textLine.contains('hwp'), isFalse);
      expect(s, contains("'hwp' || 'hwpx' => _createPlaceholderThumbnail("));
    });
  });
}
