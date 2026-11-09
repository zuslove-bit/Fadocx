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
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:fadocx/config/routing/app_router.dart';
import 'package:fadocx/config/theme/theme_provider.dart';

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
  '★': {},
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

/// 최상위 함수에서 Isolate를 만든다. State 객체(this)가 클로저에 딸려 가
/// 전송 오류가 나는 일을 막기 위해서이다.
Future<List<Map<String, Object>>> _scanInBackground(List<String> roots) {
  return Isolate.run(() => scanDocuments(roots));
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

class SimpleDocumentsScreen extends ConsumerStatefulWidget {
  const SimpleDocumentsScreen({super.key});

  @override
  ConsumerState<SimpleDocumentsScreen> createState() =>
      _SimpleDocumentsScreenState();
}

class _SimpleDocumentsScreenState extends ConsumerState<SimpleDocumentsScreen>
    with WidgetsBindingObserver {
  _Phase _phase = _Phase.loading;
  List<_Doc> _docs = const [];
  String _query = '';
  String _filter = '전체';
  // 사용자가 고른 폴더(없으면 폰 전체). Hive 'simple_prefs' 상자에 저장되어 다음 실행에도 유지된다.
  String? _folder;
  // 정렬 방식: 'date'(최신순) / 'name'(이름순) / 'size'(큰 순). 즐겨찾기 경로 모음.
  String _sort = 'date';
  Set<String> _favs = <String>{};
  // 최근 연 문서 경로(최근 것이 앞, 최대 10개).
  List<String> _recent = <String>[];

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
      _sort = (box.get('sort') as String?) ?? 'date';
      _favs = ((box.get('favs') as List?)?.cast<String>() ?? <String>[]).toSet();
      _recent = (box.get('recent') as List?)?.cast<String>().toList() ?? <String>[];
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

  // 정렬 방식을 바꾸고 저장한다.
  Future<void> _setSort(String v) async {
    setState(() => _sort = v);
    try {
      final box = await Hive.openBox('simple_prefs');
      await box.put('sort', v);
    } catch (_) {}
  }

  // 즐겨찾기(별표) 켜기/끄기. 파일 경로를 Hive에 목록으로 저장한다.
  Future<void> _toggleFav(_Doc d) async {
    setState(() {
      if (!_favs.add(d.path)) _favs.remove(d.path);
    });
    try {
      final box = await Hive.openBox('simple_prefs');
      await box.put('favs', _favs.toList());
    } catch (_) {}
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
    // 백그라운드 Isolate로 먼저 시도하고, 실패하면 화면 스레드에서 직접 훑는다
    // (예전에는 오류를 삼켜 빈 목록이 되었음).
    List<Map<String, Object>> raw;
    try {
      raw = await _scanInBackground(roots);
    } catch (_) {
      try {
        raw = scanDocuments(roots);
      } catch (_) {
        raw = const [];
      }
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

  // '최근 연 문서' 경로를 현재 불러온 문서 목록과 맞춰 본다(없어진 파일은 제외).
  List<_Doc> get _recentDocs {
    final byPath = {for (final d in _docs) d.path: d};
    return [
      for (final p in _recent)
        if (byPath[p] != null) byPath[p]!
    ];
  }

  List<_Doc> get _visible {
    final exts = _kFilters[_filter] ?? const <String>{};
    final q = _query.trim().toLowerCase();
    final r = _docs.where((d) {
      if (_filter == '★' && !_favs.contains(d.path)) return false;
      if (exts.isNotEmpty && !exts.contains(d.ext)) return false;
      if (q.isNotEmpty && !d.name.toLowerCase().contains(q)) return false;
      return true;
    }).toList();
    // 정렬: 이름순은 가나다/ABC, 크기순은 큰 파일 먼저, 기본은 최근 수정 순.
    if (_sort == 'name') {
      r.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    } else if (_sort == 'size') {
      r.sort((a, b) => b.size.compareTo(a.size));
    } else {
      r.sort((a, b) => b.modified.compareTo(a.modified));
    }
    return r;
  }

  // 문서를 열면서 '최근 연 문서' 목록 맨 앞에 기록한다.
  Future<void> _remember(_Doc d) async {
    _recent
      ..remove(d.path)
      ..insert(0, d.path);
    if (_recent.length > 10) _recent = _recent.sublist(0, 10);
    try {
      final box = await Hive.openBox('simple_prefs');
      await box.put('recent', _recent);
    } catch (_) {}
  }

  void _open(_Doc d) {
    _remember(d).then((_) {
      if (mounted) setState(() {});
    });
    context.push(
        '${RouteNames.viewer}?path=${Uri.encodeComponent(d.path)}&name=${Uri.encodeComponent(d.name)}');
  }

  // 문서를 길게 누르면 나오는 메뉴(공유 · 이름 바꾸기 · 삭제).
  void _showActions(_Doc d) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(d.folder, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            ListTile(
              leading: const Icon(Icons.share),
              title: const Text('공유'),
              onTap: () {
                Navigator.pop(ctx);
                _share(d);
              },
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('이름 바꾸기'),
              onTap: () {
                Navigator.pop(ctx);
                _rename(d);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('삭제', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(ctx);
                _delete(d);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  // 공유: 시스템 공유 창(카카오톡·메일 등)으로 파일을 보낸다.
  Future<void> _share(_Doc d) async {
    try {
      await Share.shareXFiles([XFile(d.path)]);
    } catch (_) {
      _toast('공유하지 못했습니다');
    }
  }

  // 이름 바꾸기: 같은 폴더 안에서 파일명을 바꾼다(확장자는 유지, 같은 이름이 있으면 거부).
  Future<void> _rename(_Doc d) async {
    final dot = d.name.lastIndexOf('.');
    final base = dot > 0 ? d.name.substring(0, dot) : d.name;
    final ext = dot > 0 ? d.name.substring(dot) : '';
    final c = TextEditingController(text: base);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('이름 바꾸기'),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: InputDecoration(suffixText: ext),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('취소')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('확인')),
        ],
      ),
    );
    final nb = c.text.trim();
    if (ok != true || nb.isEmpty || nb == base || nb.contains('/')) return;
    final dir = d.path.substring(0, d.path.lastIndexOf('/'));
    final np = '$dir/$nb$ext';
    try {
      if (File(np).existsSync()) {
        _toast('같은 이름의 파일이 이미 있습니다');
        return;
      }
      await File(d.path).rename(np);
      if (_favs.remove(d.path)) _favs.add(np);
      final i = _recent.indexOf(d.path);
      if (i >= 0) _recent[i] = np;
      _toast('이름을 바꿨습니다');
      await _load();
    } catch (_) {
      _toast('이름을 바꾸지 못했습니다');
    }
  }

  // 삭제: 확인창을 거친 뒤 파일을 지운다(되돌릴 수 없음).
  Future<void> _delete(_Doc d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('삭제'),
        content: Text('"${d.name}" 파일을 삭제할까요?\n삭제하면 되돌릴 수 없습니다.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('취소')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('삭제')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await File(d.path).delete();
      _favs.remove(d.path);
      _recent.remove(d.path);
      _toast('삭제했습니다');
      await _load();
    } catch (_) {
      _toast('삭제하지 못했습니다');
    }
  }

  // 폴더 메뉴: 자주 쓰는 폴더 바로가기 + 직접 선택 + 전체 보기.
  Future<void> _folderMenu() async {
    const base = '/storage/emulated/0';
    final shortcuts = <String, String>{
      '카카오톡 받은 파일': '$base/Download/KakaoTalk',
      '다운로드': '$base/Download',
      '문서': '$base/Documents',
    }..removeWhere((k, v) => !Directory(v).existsSync());
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final e in shortcuts.entries)
              ListTile(
                leading: const Icon(Icons.folder),
                title: Text(e.key),
                onTap: () => Navigator.pop(ctx, e.value),
              ),
            ListTile(
              leading: const Icon(Icons.folder_open),
              title: const Text('폴더 직접 선택'),
              onTap: () => Navigator.pop(ctx, '__pick__'),
            ),
            ListTile(
              leading: const Icon(Icons.phone_android),
              title: const Text('폰 전체 보기'),
              onTap: () => Navigator.pop(ctx, '__all__'),
            ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    if (picked == '__pick__') {
      await _pickFolder();
    } else if (picked == '__all__') {
      await _saveFolder(null);
    } else {
      await _saveFolder(picked);
    }
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
          PopupMenuButton<String>(
            tooltip: '정렬',
            icon: const Icon(Icons.sort),
            onSelected: _setSort,
            itemBuilder: (_) => [
              CheckedPopupMenuItem(
                  value: 'date', checked: _sort == 'date', child: const Text('최신순')),
              CheckedPopupMenuItem(
                  value: 'name', checked: _sort == 'name', child: const Text('이름순')),
              CheckedPopupMenuItem(
                  value: 'size', checked: _sort == 'size', child: const Text('크기순')),
            ],
          ),
          IconButton(
            tooltip: '폴더 선택',
            icon: const Icon(Icons.folder_open),
            onPressed: _folderMenu,
          ),
          IconButton(
            tooltip: '화면 밝기(다크 모드)',
            icon: const Icon(Icons.brightness_6_outlined),
            onPressed: () =>
                ref.read(themeModeProvider.notifier).toggleThemeMode(),
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
            if (_filter == '전체' && _query.trim().isEmpty && _recentDocs.isNotEmpty)
              SizedBox(
                height: 64,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  children: [
                    for (final r in _recentDocs)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: ActionChip(
                          avatar: Icon(_icon(r.ext), color: _color(r.ext), size: 18),
                          label: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 140),
                            child: Text(r.name,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                          onPressed: () => _open(r),
                        ),
                      ),
                  ],
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
                            trailing: IconButton(
                              tooltip: '즐겨찾기',
                              icon: Icon(
                                _favs.contains(d.path)
                                    ? Icons.star
                                    : Icons.star_border,
                                color: _favs.contains(d.path)
                                    ? Colors.amber
                                    : null,
                              ),
                              onPressed: () => _toggleFav(d),
                            ),
                            onTap: () => _open(d),
                            onLongPress: () => _showActions(d),
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
