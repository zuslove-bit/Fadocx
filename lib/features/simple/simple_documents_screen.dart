// 단순 문서 목록 화면 — 폰에 있는 문서(hwp·hwpx·doc·docx·ppt·pptx·xls·xlsx·pdf)를
// 한 목록으로 보여 주고, 누르면 바로 뷰어로 연다.
//
// [작동원리]
// 1) 처음 열 때 '모든 파일 접근' 권한을 확인한다(없으면 안내 + 허용 버튼).
// 2) 권한이 있으면 별도 Isolate에서 저장공간 폴더를 훑어 문서 파일만 모은다
//    (화면이 멈추지 않도록 백그라운드에서 실행, 숨김 폴더와 Android 폴더는 건너뜀).
// 3) 최근 수정 순으로 보여 주고, 검색창과 종류 칩으로 걸러 볼 수 있다.
// 4) 항목을 누르면 기존 뷰어 경로(/viewer?path=...&name=...)로 이동한다.
//    (hwp/hwpx는 HwpViewer, 나머지는 기존 뷰어가 처리)
import 'dart:io';
import 'dart:isolate';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:fadocx/config/routing/app_router.dart';

/// 목록에 보여 줄 문서 확장자.
const Set<String> kDocumentExtensions = {
  'hwp',
  'hwpx',
  'doc',
  'docx',
  'ppt',
  'pptx',
  'xls',
  'xlsx',
  'pdf',
};

/// 칩(필터) 이름 → 해당 확장자.
const Map<String, Set<String>> _kFilters = {
  '전체': {},
  '한글': {'hwp', 'hwpx'},
  'PDF': {'pdf'},
  'Word': {'doc', 'docx'},
  'Excel': {'xls', 'xlsx'},
  'PPT': {'ppt', 'pptx'},
};

/// Isolate에서 실행되는 스캔 함수(최상위 함수여야 한다).
/// 반환값은 Isolate 경계를 넘길 수 있는 단순 Map 목록이다.
List<Map<String, Object>> scanDocuments(List<String> roots) {
  final result = <Map<String, Object>>[];
  // 스택에 (경로, 깊이)를 쌓아 가며 폴더를 순회한다. 재귀보다 안전하다.
  final stack = <MapEntry<String, int>>[
    for (final r in roots) MapEntry(r, 0),
  ];
  while (stack.isNotEmpty) {
    final cur = stack.removeLast();
    List<FileSystemEntity> entries;
    try {
      entries = Directory(cur.key).listSync(followLinks: false);
    } catch (_) {
      continue; // 읽을 수 없는 폴더는 건너뜀
    }
    for (final e in entries) {
      final name = e.path.split('/').last;
      if (name.startsWith('.')) continue; // 숨김 파일/폴더
      if (e is Directory) {
        if (cur.value >= 10) continue; // 너무 깊은 폴더는 제외
        if (cur.value == 0 && name == 'Android') continue; // 앱 전용 폴더
        stack.add(MapEntry(e.path, cur.value + 1));
      } else if (e is File) {
        final dot = name.lastIndexOf('.');
        if (dot <= 0) continue;
        final ext = name.substring(dot + 1).toLowerCase();
        if (!kDocumentExtensions.contains(ext)) continue;
        try {
          final st = e.statSync();
          result.add(<String, Object>{
            'path': e.path,
            'name': name,
            'ext': ext,
            'size': st.size,
            'modified': st.modified.millisecondsSinceEpoch,
          });
        } catch (_) {}
      }
    }
  }
  return result;
}

class _Doc {
  _Doc(this.path, this.name, this.ext, this.size, this.modified);
  final String path;
  final String name;
  final String ext;
  final int size;
  final DateTime modified;

  String get folder {
    final i = path.lastIndexOf('/');
    final dir = i > 0 ? path.substring(0, i) : path;
    return dir.replaceFirst('/storage/emulated/0', '내장 저장소');
  }
}

enum _Phase { loading, needPermission, ready }

class SimpleDocumentsScreen extends StatefulWidget {
  const SimpleDocumentsScreen({super.key});

  @override
  State<SimpleDocumentsScreen> createState() => _SimpleDocumentsScreenState();
}

class _SimpleDocumentsScreenState extends State<SimpleDocumentsScreen>
    with WidgetsBindingObserver {
  _Phase _phase = _Phase.loading;
  List<_Doc> _docs = const [];
  String _query = '';
  String _filter = '전체';
  // 사용자가 고른 폴더(없으면 폰 전체). Hive 'simple_prefs' 상자에 저장되어 다음 실행에도 유지된다.
  String? _folder;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _restoreFolder().then((_) => _load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // 설정 화면에서 권한을 허용하고 돌아오면 자동으로 다시 불러온다.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _phase == _Phase.needPermission) {
      _load();
    }
  }

  // 저장된 폴더 선택값을 불러온다(실패해도 전체 검색으로 동작).
  Future<void> _restoreFolder() async {
    try {
      final box = await Hive.openBox('simple_prefs');
      final f = box.get('folder') as String?;
      if (f != null && Directory(f).existsSync()) _folder = f;
    } catch (_) {}
  }

  // 폴더 선택 창을 열어 고른 폴더만 보도록 한다. 취소하면 그대로 둔다.
  Future<void> _pickFolder() async {
    final dir = await FilePicker.getDirectoryPath(dialogTitle: '문서 폴더 선택');
    if (dir == null) return;
    await _saveFolder(dir);
  }

  Future<void> _saveFolder(String? dir) async {
    _folder = dir;
    try {
      final box = await Hive.openBox('simple_prefs');
      if (dir == null) {
        await box.delete('folder');
      } else {
        await box.put('folder', dir);
      }
    } catch (_) {}
    await _load();
  }

  Future<bool> _hasPermission() async {
    if (!Platform.isAndroid) return true;
    // 안드로이드 13+에서는 Permission.storage가 실제 접근 없이도 '허용'으로 나오므로
    // 반드시 '모든 파일 접근(manageExternalStorage)'만 기준으로 삼는다.
    return await Permission.manageExternalStorage.isGranted;
  }

  Future<void> _requestPermission() async {
    final status = await Permission.manageExternalStorage.request();
    if (!status.isGranted) {
      // 시스템 설정 화면으로 보내 직접 허용하게 한다.
      await openAppSettings();
    }
    await _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _phase = _Phase.loading);
    if (!await _hasPermission()) {
      if (mounted) setState(() => _phase = _Phase.needPermission);
      return;
    }
    // 내장 저장소 + (있다면) SD카드 같은 외부 저장소
    // 폴더를 골랐다면 그 폴더만, 아니면 폰 전체(+SD카드)를 훑는다.
    final roots = <String>[];
    if (_folder != null) {
      roots.add(_folder!);
    } else {
      roots.add('/storage/emulated/0');
      try {
        for (final e in Directory('/storage').listSync(followLinks: false)) {
          final n = e.path.split('/').last;
          if (e is Directory && n != 'emulated' && n != 'self') {
            roots.add(e.path);
          }
        }
      } catch (_) {}
    }
    List<Map<String, Object>> raw;
    try {
      raw = await Isolate.run(() => scanDocuments(roots));
    } catch (_) {
      raw = const [];
    }
    final docs = raw
        .map((m) => _Doc(
              m['path'] as String,
              m['name'] as String,
              m['ext'] as String,
              m['size'] as int,
              DateTime.fromMillisecondsSinceEpoch(m['modified'] as int),
            ))
        .toList()
      ..sort((a, b) => b.modified.compareTo(a.modified));
    if (!mounted) return;
    setState(() {
      _docs = docs;
      _phase = _Phase.ready;
    });
  }

  List<_Doc> get _visible {
    final exts = _kFilters[_filter] ?? const <String>{};
    final q = _query.trim().toLowerCase();
    return _docs.where((d) {
      if (exts.isNotEmpty && !exts.contains(d.ext)) return false;
      if (q.isNotEmpty && !d.name.toLowerCase().contains(q)) return false;
      return true;
    }).toList();
  }

  void _open(_Doc d) {
    context.push(
        '${RouteNames.viewer}?path=${Uri.encodeComponent(d.path)}&name=${Uri.encodeComponent(d.name)}');
  }

  static String _size(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
    return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  static String _date(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static IconData _icon(String ext) {
    switch (ext) {
      case 'pdf':
        return Icons.picture_as_pdf;
      case 'xls':
      case 'xlsx':
        return Icons.table_chart;
      case 'ppt':
      case 'pptx':
        return Icons.slideshow;
      case 'hwp':
      case 'hwpx':
        return Icons.description;
      default:
        return Icons.article;
    }
  }

  static Color _color(String ext) {
    switch (ext) {
      case 'pdf':
        return const Color(0xFFD32F2F);
      case 'xls':
      case 'xlsx':
        return const Color(0xFF2E7D32);
      case 'ppt':
      case 'pptx':
        return const Color(0xFFE65100);
      case 'hwp':
      case 'hwpx':
        return const Color(0xFF1565C0);
      default:
        return const Color(0xFF3949AB);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('내 문서'),
        actions: [
          IconButton(
            tooltip: '폴더 선택',
            icon: const Icon(Icons.folder_open),
            onPressed: _pickFolder,
          ),
          IconButton(
            tooltip: '새로고침',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: SafeArea(child: _body(context)),
    );
  }

  Widget _body(BuildContext context) {
    switch (_phase) {
      case _Phase.loading:
        return const Center(child: CircularProgressIndicator());
      case _Phase.needPermission:
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.folder_open, size: 56),
                const SizedBox(height: 16),
                const Text(
                  '폰에 있는 문서를 목록으로 보려면\n\'모든 파일 접근\' 권한이 필요합니다.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _requestPermission,
                  child: const Text('권한 허용'),
                ),
              ],
            ),
          ),
        );
      case _Phase.ready:
        final list = _visible;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: TextField(
                decoration: InputDecoration(
                  hintText: '파일 이름 검색',
                  prefixIcon: const Icon(Icons.search),
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                children: [
                  for (final k in _kFilters.keys)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: ChoiceChip(
                        label: Text(k),
                        selected: _filter == k,
                        onSelected: (_) => setState(() => _filter = k),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('${list.length}개',
                    style: Theme.of(context).textTheme.bodySmall),
              ),
            ),
            if (_folder != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                child: Row(
                  children: [
                    const Icon(Icons.folder, size: 16),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        _folder!.replaceFirst('/storage/emulated/0', '내장 저장소'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    TextButton(
                      onPressed: () => _saveFolder(null),
                      child: const Text('전체 보기'),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: list.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('문서가 없습니다'),
                          const SizedBox(height: 12),
                          TextButton(
                            onPressed: _requestPermission,
                            child: const Text('파일 접근 권한 다시 설정'),
                          ),
                        ],
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.builder(
                        itemCount: list.length,
                        itemBuilder: (context, i) {
                          final d = list[i];
                          return ListTile(
                            leading: Icon(_icon(d.ext), color: _color(d.ext)),
                            title: Text(d.name,
                                maxLines: 2, overflow: TextOverflow.ellipsis),
                            subtitle: Text(
                              '${_date(d.modified)} · ${_size(d.size)}\n${d.folder}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            isThreeLine: true,
                            onTap: () => _open(d),
                          );
                        },
                      ),
                    ),
            ),
          ],
        );
    }
  }
}
