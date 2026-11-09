// [작동원리] simple_icons 패키지(14.6.1)는 최신 Flutter에서 IconData를 상속할 수 없어
// 컴파일이 깨진다. 앱이 쓰는 브랜드 아이콘은 7개뿐이라, 패키지를 걷어내고
// 같은 이름(SimpleIcons.xxx)의 Material 아이콘 대체 클래스를 제공한다.
// 기존 코드는 import 경로만 바꾸면 그대로 동작한다.
import 'package:flutter/material.dart';

class SimpleIcons {
  SimpleIcons._();

  static const IconData github = Icons.code;
  static const IconData discord = Icons.forum;
  static const IconData android = Icons.android;
  static const IconData linux = Icons.computer;
  static const IconData apple = Icons.apple;
  static const IconData whatsapp = Icons.chat;
  static const IconData patreon = Icons.favorite;
}
