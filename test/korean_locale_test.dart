// 한국어(ko) 지원이 빠짐없이 연결되어 있는지 확인하는 회귀 테스트.
//
// [작동원리] 번역 파일(arb)의 키가 영어 원본과 일치하는지, 생성된 Dart 클래스와
// 로케일 등록이 되어 있는지 파일 내용을 읽어 검사한다. (화면 표시는 기기에서 확인)
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _arb(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

void main() {
  group('한국어 로케일', () {
    test('app_ko.arb가 영어 원본과 같은 키를 가진다', () {
      final en = _arb('lib/l10n/app_en.arb')
        ..removeWhere((k, _) => k.startsWith('@'));
      final ko = _arb('lib/l10n/app_ko.arb')
        ..removeWhere((k, _) => k.startsWith('@'));
      expect(ko.keys.toSet(), en.keys.toSet());
    });

    test('자리표시자({name})가 영어 원본과 일치한다', () {
      final re = RegExp(r'\{(\w+)[,}]');
      final en = _arb('lib/l10n/app_en.arb');
      final ko = _arb('lib/l10n/app_ko.arb');
      for (final k in en.keys.where((k) => !k.startsWith('@'))) {
        final a = re.allMatches(en[k] as String).map((m) => m[1]).toSet();
        final b = re.allMatches(ko[k] as String).map((m) => m[1]).toSet();
        expect(b, a, reason: '키 $k 의 자리표시자가 다릅니다');
      }
    });

    test('로케일 등록과 언어 선택 항목이 있다', () {
      final l = File('lib/l10n/app_localizations.dart').readAsStringSync();
      expect(l, contains("Locale('ko')"));
      expect(l, contains('AppLocalizationsKo()'));
      final s = File(
              'lib/features/settings/presentation/screens/settings_screen.dart')
          .readAsStringSync();
      expect(s, contains("pickLang('ko')"));
    });

    test('기본 언어가 한국어다', () {
      expect(File('lib/main.dart').readAsStringSync(),
          contains("String savedLanguage = 'ko'"));
    });
  });
}
