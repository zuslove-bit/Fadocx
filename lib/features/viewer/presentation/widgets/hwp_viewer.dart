import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_rhwp/flutter_rhwp.dart';
import 'package:logger/logger.dart';

/// HWP / HWPX 문서 뷰어.
///
/// [작동원리]
/// 1. 파일을 바이트로 읽는다.
/// 2. `Rhwp.open`이 rhwp(Rust) 파서로 HWP 5.0(.hwp) / OWPML(.hwpx)을 모두 해석한다.
/// 3. `RhwpViewer`가 페이지를 SVG로 렌더링해 스크롤/확대 가능한 화면으로 보여준다.
///
/// LibreOffice Kit(LOKit)과 독립적으로 동작하므로 doc/ppt 등 기존 경로에는 영향이 없다.
class HwpViewer extends StatefulWidget {
  final String filePath;
  final String? fileName;
  final VoidCallback? onTap;

  const HwpViewer({
    super.key,
    required this.filePath,
    this.fileName,
    this.onTap,
  });

  @override
  State<HwpViewer> createState() => _HwpViewerState();
}

class _HwpViewerState extends State<HwpViewer> {
  static final Logger _log = Logger();

  /// 문서 열기 결과. FutureBuilder가 로딩/오류/완료 상태를 나눠 처리한다.
  late Future<RhwpDocument> _documentFuture;
  RhwpDocument? _document;

  @override
  void initState() {
    super.initState();
    _documentFuture = _open();
  }

  /// 파일을 읽어 rhwp 문서 객체로 변환한다.
  Future<RhwpDocument> _open() async {
    _log.d('HWP open: ${widget.filePath}');
    final bytes = await File(widget.filePath).readAsBytes();
    final doc = await Rhwp.open(
      bytes,
      fileName: widget.fileName ?? widget.filePath.split('/').last,
    );
    _document = doc;
    return doc;
  }

  @override
  void dispose() {
    // 네이티브(Rust) 쪽 메모리를 해제한다.
    _document?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<RhwpDocument>(
      future: _documentFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError || snapshot.data == null) {
          _log.e('HWP open failed', error: snapshot.error);
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                '한글 문서를 열 수 없습니다.\n'
                '암호가 걸렸거나 손상된 파일일 수 있습니다.\n\n'
                '${snapshot.error ?? ''}',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: widget.onTap,
          child: RhwpViewer(document: snapshot.data!),
        );
      },
    );
  }
}
