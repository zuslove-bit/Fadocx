import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:go_router/go_router.dart';
import 'package:fadocx/config/routing/app_router.dart';
import 'package:fadocx/config/theme/app_theme.dart';
import 'package:fadocx/config/theme/theme_provider.dart';
import 'package:logger/logger.dart';
import 'package:fadocx/features/settings/data/datasources/hive_datasource.dart';
import 'package:fadocx/features/settings/presentation/providers/locale_provider.dart';
import 'package:fadocx/services/file_intent_service.dart';
import 'package:fadocx/l10n/app_localizations.dart';
import 'package:flutter/services.dart';
import 'dart:async';

final log = Logger();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Hive FIRST - pre-opens boxes
  await HiveDatasource.initialize();

  // Load theme from Hive to set correct system UI overlay style
  String savedTheme = 'dark'; // Default fallback
  String savedLanguage = 'ko'; // 기본 언어: 한국어 (저장된 값이 없을 때)
  bool onboardingSeen = true;
  bool reShowOnboarding = false;
  try {
    final settings = await HiveDatasource().getSettings();
    if (settings?.theme != null) {
      savedTheme = settings!.theme;
      log.i('📱 Theme loaded from Hive: $savedTheme');
    }
    if (settings?.language != null) {
      // 단순 뷰어: 저장된 언어(기본 'en')를 쓰지 않고 항상 한국어로 고정한다.
      savedLanguage = 'ko';
      log.i('🌐 Language loaded from Hive: $savedLanguage');
    }
    onboardingSeen = settings?.hasDismissedWelcome ?? false;
    reShowOnboarding = settings?.showOnboardingNextLaunch ?? false;
  } catch (e) {
    log.w('⚠️ Could not load theme from Hive, using default: $e');
  }

  // Show onboarding on first launch or if user toggled re-show
  // 단순 뷰어: 첫 실행 시작 안내(온보딩)는 생략한다.
  // ignore: dead_code
  if (false && (!onboardingSeen || reShowOnboarding)) {
    setInitialRoute(RouteNames.onboarding);
    log.i(
        '🚀 Showing onboarding (firstLaunch: ${!onboardingSeen}, reShow: $reShowOnboarding)');
  }

  // Set system UI overlay style to match saved theme
  // IMPORTANT: This sets the INITIAL state. FloatingDockScaffold will update it dynamically.
  final isDarkTheme = savedTheme.toLowerCase() == 'dark';
  SystemChrome.setSystemUIOverlayStyle(
    SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: isDarkTheme ? Brightness.light : Brightness.dark,
      statusBarBrightness:
          isDarkTheme ? Brightness.dark : Brightness.light, // For iOS
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness:
          isDarkTheme ? Brightness.light : Brightness.dark,
    ),
  );
  log.d('✅ System UI overlay style set for $savedTheme theme');

  // Clear old thumbnail cache to regenerate with new system
  try {
    await HiveDatasource().clearThumbnailCache();
    log.i(
        '✅ Thumbnail cache cleared on startup - will regenerate with new system');
  } catch (e) {
    log.e('Error clearing thumbnail cache on startup', error: e);
  }

  runApp(
    ProviderScope(
      overrides: [
        initialThemeProvider.overrideWithValue(savedTheme),
        initialLocaleProvider.overrideWithValue(savedLanguage),
      ],
      child: const MyApp(),
    ),
  );
}

class MyApp extends ConsumerStatefulWidget {
  const MyApp({super.key});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _MyAppState();
}

class _MyAppState extends ConsumerState<MyApp> {
  StreamSubscription<String>? _fileIntentSub;
  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    // Create router ONCE - prevents navigation reset on theme change
    _router = createGoRouter();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fileIntentSub = FileIntentService.fileIntentStream.listen((filePath) {
        if (!mounted) return;
        final encodedPath = Uri.encodeComponent(filePath);
        final fileName = filePath.split('/').last;
        log.i('File intent: navigating to viewer: $fileName');
        // ext=1: 다른 앱(내 파일 등)에서 연 문서임을 표시한다(닫을 때 원래 앱으로 복귀).
        // 이미 열려 있는 문서 화면이 있으면 먼저 정리해 이전 문서 상태가 섞이지 않게 한다.
        _router.go('/');
        _router.push('/viewer?path=$encodedPath&name=$fileName&ext=1');
      }, onError: (e) => log.e('File intent error: $e'));

      // Initialize file intent service AFTER listener is set up
      // so cold-start intents are not missed
      FileIntentService.initialize();
    });
  }

  @override
  void dispose() {
    _fileIntentSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(themeModeProvider);
    final locale = ref.watch(localeProvider);

    return MaterialApp.router(
      title: '문서 뷰어',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: themeMode,
      locale: locale,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      // Use the pre-created router - never changes on rebuild
      routerConfig: _router,
    );
  }
}
