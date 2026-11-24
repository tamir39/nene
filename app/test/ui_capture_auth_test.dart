// Renders review/report screenshots of sign-in, its session states and the
// transaction-security screens with the bundled Be Vietnam Pro font. Skipped
// in ordinary runs; generate with:
//   flutter test test/ui_capture_auth_test.dart --dart-define=CAPTURE_UI=true
// Images are written to the ignored ../.tmp/ui-review/ folder. All keys,
// codes and people below are synthetic.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nene_app/data/account_history_api.dart';
import 'package:nene_app/data/assistant_api.dart';
import 'package:nene_app/data/branches_api.dart';
import 'package:nene_app/data/profile_api.dart';
import 'package:nene_app/data/security_api.dart';
import 'package:nene_app/data/session_owner.dart';
import 'package:nene_app/data/user_profile.dart';
import 'package:nene_app/nene_app.dart';
import 'package:nene_app/session_controller.dart';

import 'security_screen_test.dart' show Port;
import 'test_doubles.dart';

const _capture = bool.fromEnvironment('CAPTURE_UI');
final _base = Uri.parse('http://localhost/api/v1/');
final _offline = MockClient((_) async => http.Response('{}', 404));
const _key = ValueKey('ui-capture');
const _secret = 'SYNTHETICDEMOKEY2345NENEABCDEFGH';
const _codes = [
  'DEMO1-7KQ2M',
  'DEMO2-X9PLA',
  'DEMO3-4TRWE',
  'DEMO4-M2ZQK',
  'DEMO5-8HNVD',
  'DEMO6-C3JYS',
  'DEMO7-Q6BTF',
  'DEMO8-W5LGP',
];

const _an = UserProfile(
  id: 'user-id',
  email: 'an@example.invalid',
  displayName: 'Nguyễn Văn An',
  role: AppRole.customer,
  phone: '+84 901 000 001',
  address: 'Quận 7, TP. Hồ Chí Minh',
);

/// Synthetic security backend whose state each capture sets up front.
class _Security {
  String state = 'not_set_up';
  int remaining = 8;
  Map<String, dynamic>? management;

  static Map<String, dynamic> change(
    String step, {
    String purpose = 'codes',
    String proofKind = 'current_authenticator',
    bool canResume = true,
  }) => {
    'requestId': 'request',
    'revision': 2,
    'purpose': purpose,
    'step': step,
    'expiresAt': DateTime.now()
        .add(const Duration(minutes: 10))
        .toIso8601String(),
    'sameSession': true,
    'expired': false,
    'canResume': canResume,
    'proofKind': proofKind,
  };

  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path;
    final Map<String, dynamic> body;
    if (path.endsWith('/me/security')) {
      body = {'state': state};
    } else if (path.endsWith('/setup')) {
      body = {'requestId': 'setup', 'revision': 1, 'secret': _secret};
    } else if (path.endsWith('/management')) {
      body = {'remaining': remaining, 'management': management};
    } else if (path.endsWith('/management/enroll')) {
      management = {...management!, 'step': 'pending'};
      body = {'secret': _secret};
    } else if (path.endsWith('/management/issue-codes')) {
      management = {...management!, 'step': 'codes_shown'};
      body = {
        'requestId': 'request',
        'revision': 2,
        'purpose': 'manage-issue',
        'accessToken': 'test',
        'refreshToken': 'test',
        'codes': _codes,
      };
    } else {
      body = {};
    }
    return http.Response(jsonEncode(body), 200);
  }
}

Future<void> _fonts(WidgetTester tester) async {
  final sdk = Platform.environment['FLUTTER_ROOT'] ?? '../.tools/flutter';
  Future<ByteData> bytes(String path) =>
      File(path).readAsBytes().then(ByteData.sublistView);
  await tester.runAsync(() async {
    final family = FontLoader('BeVietnamPro');
    for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      family.addFont(bytes('assets/fonts/BeVietnamPro-$weight.ttf'));
    }
    await family.load();
    await (FontLoader('MaterialIcons')..addFont(
          bytes(
            '$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ),
        ))
        .load();
    // Stand-in for the platform "monospace" family used by setup keys and
    // recovery codes. Without it the screens fall back to Be Vietnam Pro.
    final mono = File('C:/Windows/Fonts/consola.ttf');
    if (mono.existsSync()) {
      final family = FontLoader('monospace')..addFont(bytes(mono.path));
      final bold = File('C:/Windows/Fonts/consolab.ttf');
      if (bold.existsSync()) family.addFont(bytes(bold.path));
      await family.load();
    }
  });
}

Future<void> _view(
  WidgetTester tester, {
  double width = 390,
  double height = 844,
  double statusBar = 0,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  tester.view.padding = FakeViewPadding(top: statusBar);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPadding);
  await _fonts(tester);
}

/// Status-bar height simulated for full-bleed session screens.
const _statusBar = 32.0;

/// Mounts the app on its session screens (signed out, loading, failure).
Future<FakeAuth> _mountSession(
  WidgetTester tester, {
  FakeAuth? auth,
  FakeProfiles? profiles,
  double height = 844,
  bool settle = true,
}) async {
  await _view(tester, height: height, statusBar: _statusBar);
  final fake = auth ?? FakeAuth();
  await tester.pumpWidget(
    RepaintBoundary(
      key: _key,
      child: NeneApp(
        controller: SessionController(
          auth: fake,
          profiles: profiles ?? FakeProfiles(),
        ),
        banking: FakeBanking(),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump(const Duration(milliseconds: 400));
  }
  return fake;
}

/// Mounts the signed-in customer app and opens Profile → Transaction security.
Future<void> _mountSecurity(
  WidgetTester tester,
  _Security backend, {
  double height = 844,
  bool manage = false,
}) async {
  await _view(tester, height: height);
  final session = SessionController(
    auth: FakeAuth()
      ..userId = _an.id
      ..accessToken = 'test-token',
    profiles: FakeProfiles()..fetch = (_) async => _an,
  );
  await session.loadProfile();
  final credentials = SessionOwner(Port());
  await credentials.signIn('', '');
  addTearDown(credentials.dispose);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _key,
      child: NeneApp(
        controller: session,
        banking: FakeBanking()..accounts = (_) async => [demoAccount],
        security: SecurityApi(
          baseUrl: _base,
          owner: credentials,
          client: MockClient(backend.handle),
        ),
        history: AccountHistoryApi(baseUrl: _base, client: _offline),
        branches: BranchesApi(baseUrl: _base, client: _offline),
        assistant: AssistantApi(baseUrl: _base, client: _offline),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Profile'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Transaction security'));
  await tester.pumpAndSettle();
  if (manage) await _tap(tester, 'Manage authenticator and recovery');
}

Future<void> _tap(WidgetTester tester, String label) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text(label));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

Future<void> _top(WidgetTester tester) async {
  final scrollable = find.byType(Scrollable);
  if (scrollable.evaluate().isEmpty) return;
  final state = tester.state<ScrollableState>(scrollable.first);
  state.position.jumpTo(0);
  await tester.pumpAndSettle();
}

Future<void> _shoot(
  WidgetTester tester,
  String name, {
  bool settle = true,
}) async {
  if (settle) await tester.pumpAndSettle();
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(_key));
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('../.tmp/ui-review/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
  expect(tester.takeException(), isNull);
}

void main() {
  testWidgets('capture sign-in', (tester) async {
    if (!_capture) return;
    await _mountSession(tester);
    await _shoot(tester, 'auth-sign-in');
  });

  testWidgets('capture sign-in validation', (tester) async {
    if (!_capture) return;
    await _mountSession(tester);
    await _tap(tester, 'Sign in');
    await _top(tester);
    await _shoot(tester, 'auth-sign-in-validation');
  });

  testWidgets('capture sign-in failure', (tester) async {
    if (!_capture) return;
    final auth = FakeAuth()..signInError = StateError('Unavailable');
    await _mountSession(tester, auth: auth);
    await tester.enterText(find.byType(TextFormField).at(0), 'an@example.test');
    await tester.enterText(find.byType(TextFormField).at(1), 'synthetic');
    await _tap(tester, 'Sign in');
    await _top(tester);
    await _shoot(tester, 'auth-sign-in-error');
  });

  testWidgets('capture sign-in at large text on a small phone', (tester) async {
    if (!_capture) return;
    // Mirrors widget_test.dart's 2x text check on a 320x640 phone.
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _view(tester, width: 320, height: 640, statusBar: _statusBar);
    await tester.pumpWidget(
      RepaintBoundary(
        key: _key,
        child: NeneApp(
          controller: SessionController(
            auth: FakeAuth(),
            profiles: FakeProfiles(),
          ),
          banking: FakeBanking(),
        ),
      ),
    );
    await _shoot(tester, 'auth-sign-in-large-text');
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    scroll.position.jumpTo(scroll.position.maxScrollExtent);
    await _shoot(tester, 'auth-sign-in-large-text-end');
  });

  testWidgets('capture session loading', (tester) async {
    if (!_capture) return;
    final pending = Completer<UserProfile>();
    await _mountSession(
      tester,
      auth: FakeAuth()
        ..userId = 'user-id'
        ..accessToken = 'test-token',
      profiles: FakeProfiles()..fetch = (_) => pending.future,
      settle: false,
    );
    await _shoot(tester, 'auth-loading', settle: false);
  });

  testWidgets('capture unconfigured build', (tester) async {
    if (!_capture) return;
    await _view(tester);
    await tester.pumpWidget(const RepaintBoundary(key: _key, child: NeneApp()));
    await _shoot(tester, 'auth-unconfigured');
  });

  testWidgets('capture profile unavailable', (tester) async {
    if (!_capture) return;
    await _mountSession(
      tester,
      auth: FakeAuth()
        ..userId = 'user-id'
        ..accessToken = 'test-token',
      profiles: FakeProfiles()
        ..fetch = (_) async => throw const ApiException(ApiFailure.forbidden),
    );
    await _shoot(tester, 'auth-profile-unavailable');
  });

  testWidgets('capture security not set up', (tester) async {
    if (!_capture) return;
    await _mountSecurity(tester, _Security());
    await _shoot(tester, 'auth-security-not-set-up');
  });

  testWidgets('capture security setup steps', (tester) async {
    if (!_capture) return;
    await _mountSecurity(tester, _Security(), height: 1240);
    await _tap(tester, 'Set up authenticator');
    await tester.enterText(find.byType(TextField), '482');
    await _top(tester);
    await _shoot(tester, 'auth-security-setup');
  });

  testWidgets('capture security setup at large text', (tester) async {
    if (!_capture) return;
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _mountSecurity(tester, _Security(), height: 2000);
    await _tap(tester, 'Set up authenticator');
    await _top(tester);
    await _shoot(tester, 'auth-security-setup-large-text');
  });

  testWidgets('capture security ready', (tester) async {
    if (!_capture) return;
    await _mountSecurity(tester, _Security()..state = 'ready');
    await _shoot(tester, 'auth-security-ready');
  });

  testWidgets('capture security needs attention', (tester) async {
    if (!_capture) return;
    await _mountSecurity(tester, _Security()..state = 'restricted');
    await _shoot(tester, 'auth-security-attention');
  });

  testWidgets('capture management overview', (tester) async {
    if (!_capture) return;
    final backend = _Security()..state = 'ready';
    await _mountSecurity(tester, backend, height: 1120, manage: true);
    await _shoot(tester, 'auth-manage-overview');
  });

  testWidgets('capture management proof', (tester) async {
    if (!_capture) return;
    final backend = _Security()..state = 'ready';
    await _mountSecurity(tester, backend, height: 1000);
    backend.management = _Security.change('proof', purpose: 'replace');
    await _tap(tester, 'Manage authenticator and recovery');
    await _shoot(tester, 'auth-manage-proof');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('capture management replacement key', (tester) async {
    if (!_capture) return;
    final backend = _Security()..state = 'restricted';
    await _mountSecurity(tester, backend, height: 1240);
    backend.management = _Security.change(
      'authorized',
      purpose: 'replace',
      proofKind: 'new_authenticator',
    );
    await _tap(tester, 'Manage authenticator and recovery');
    await _shoot(tester, 'auth-manage-authorized');
    await _tap(tester, 'Set up replacement');
    await _top(tester);
    await _shoot(tester, 'auth-manage-replacement-key');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('capture management recovery codes', (tester) async {
    if (!_capture) return;
    final backend = _Security()..state = 'restricted';
    await _mountSecurity(tester, backend, height: 1300);
    backend.management = _Security.change('verified');
    await _tap(tester, 'Manage authenticator and recovery');
    await _shoot(tester, 'auth-manage-verified');
    await _tap(tester, 'Replace the previous recovery-code set.');
    await tester.enterText(find.byType(TextField), '123456');
    await _tap(tester, 'Create new recovery codes');
    await _top(tester);
    await _shoot(tester, 'auth-manage-codes');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('capture management resume and uncertain states', (tester) async {
    if (!_capture) return;
    final backend = _Security()..state = 'restricted';
    await _mountSecurity(tester, backend, height: 1100);
    backend.management = _Security.change('codes_shown');
    await _tap(tester, 'Manage authenticator and recovery');
    await _shoot(tester, 'auth-manage-resume');
    backend.management = _Security.change('issuing', canResume: false);
    await _tap(tester, 'Check status');
    await _top(tester);
    await _shoot(tester, 'auth-manage-uncertain');
    await tester.pumpWidget(const SizedBox());
  });
}
