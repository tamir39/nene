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
import 'package:nene_app/data/security_api.dart';
import 'package:nene_app/data/session_owner.dart';
import 'package:nene_app/ui/security_management_screen.dart';
import 'package:nene_app/ui/nene_brand.dart';
import 'security_screen_test.dart' show Port;

Map<String, dynamic> management(String step) => {
  'requestId': 'request',
  'revision': 2,
  'purpose': 'codes',
  'step': step,
  'expiresAt': DateTime.now()
      .add(const Duration(minutes: 10))
      .toIso8601String(),
  'sameSession': true,
  'expired': false,
  'canResume': true,
  'proofKind': 'current_authenticator',
};
Future<void> tap(WidgetTester tester, String label) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text(label));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

Future<SessionOwner> showScreen(
  WidgetTester tester,
  Future<http.Response> Function(http.Request) handler,
) async {
  tester.view.physicalSize = const Size(390, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final owner = SessionOwner(Port());
  await owner.signIn('', '');
  addTearDown(owner.dispose);
  final theme = neneTheme();
  await tester.pumpWidget(
    MaterialApp(
      theme: theme.copyWith(
        filledButtonTheme: const bool.fromEnvironment('CAPTURE_SECURITY_UI')
            ? FilledButtonThemeData(
                style: theme.filledButtonTheme.style!.copyWith(
                  textStyle: const WidgetStatePropertyAll(
                    TextStyle(fontFamily: 'SecurityTestFont', fontSize: 16),
                  ),
                ),
              )
            : theme.filledButtonTheme,
        textTheme: theme.textTheme.apply(
          fontFamily: const bool.fromEnvironment('CAPTURE_SECURITY_UI')
              ? 'SecurityTestFont'
              : null,
        ),
      ),
      home: RepaintBoundary(
        key: const ValueKey('capture'),
        child: Scaffold(
          body: SecurityManagementScreen(
            api: SecurityApi(
              baseUrl: Uri.parse('http://localhost/api/v1/'),
              owner: owner,
              client: MockClient(handler),
            ),
            onBack: () {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return owner;
}

http.Response json(Object body) => http.Response(jsonEncode(body), 200);
void main() {
  setUpAll(() async {
    if (!const bool.fromEnvironment('CAPTURE_SECURITY_UI')) return;
    final sdk = Platform.environment['FLUTTER_ROOT'] ?? '../.tools/flutter';
    await (FontLoader('SecurityTestFont')..addFont(
          File(
            '$sdk/bin/cache/artifacts/material_fonts/roboto-regular.ttf',
          ).readAsBytes().then(ByteData.sublistView),
        ))
        .load();
  });
  testWidgets(
    'narrow management overview offers three paths and explains lost-both limit',
    (tester) async {
      await showScreen(
        tester,
        (_) async => json({'remaining': 0, 'management': null}),
      );
      expect(find.text('Replace authenticator'), findsOneWidget);
      expect(
        find.textContaining('password alone cannot reset'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      if (const bool.fromEnvironment('CAPTURE_SECURITY_UI')) {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('capture')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('../.tmp/security-ui/management.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }
    },
  );
  testWidgets(
    'code issuance requires consent, hides on background and finishes only after save',
    (tester) async {
      var step = 'verified', finished = false, issued = 0;
      final owner = await showScreen(tester, (req) async {
        if (req.url.path.endsWith('/issue-codes')) {
          issued++;
          step = 'codes_shown';
          return json({
            'requestId': 'request',
            'revision': 2,
            'purpose': 'manage-issue',
            'accessToken': 'test',
            'refreshToken': 'test',
            'codes': ['SYNTHETIC-CODE-ONLY'],
          });
        }
        if (req.url.path.endsWith('/finish')) {
          expect(jsonDecode(req.body)['saved'], true);
          finished = true;
          return json({'signedOut': true});
        }
        return json({'remaining': 10, 'management': management(step)});
      });
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Create new recovery codes'),
            )
            .onPressed,
        isNull,
      );
      await tap(tester, 'Replace the previous recovery-code set.');
      await tester.enterText(find.byType(TextField), '123456');
      await tap(tester, 'Create new recovery codes');
      expect(issued, 1);
      expect(find.text('SYNTHETIC-CODE-ONLY'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(
                FilledButton,
                'Finish and sign out everywhere',
              ),
            )
            .onPressed,
        isNull,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(find.text('SYNTHETIC-CODE-ONLY'), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tap(tester, 'I saved my new recovery codes.');
      await tap(tester, 'Finish and sign out everywhere');
      expect(finished, true);
      expect(owner.session, isNull);
      expect(find.text('SYNTHETIC-CODE-ONLY'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'lost display requires explicit fresh proof; unknown issuance offers no repeat',
    (tester) async {
      var step = 'codes_shown';
      await showScreen(
        tester,
        (_) async => json({
          'remaining': 10,
          'management': {...management(step), 'canResume': step != 'issuing'},
        }),
      );
      expect(find.text('Resume with fresh proof'), findsOneWidget);
      expect(find.text('Finish and sign out everywhere'), findsNothing);
      step = 'issuing';
      await tap(tester, 'Check status');
      expect(find.text('Resume with fresh proof'), findsNothing);
      expect(find.text('Create new recovery codes'), findsNothing);
      expect(
        find.textContaining('provider request may have completed'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  test('late non-rotating secret response after logout is discarded', () async {
    final owner = SessionOwner(Port());
    await owner.signIn('', '');
    addTearDown(owner.dispose);
    final response = Completer<String>(), started = Completer<void>();
    final future = owner.execute((_) {
      started.complete();
      return response.future;
    });
    final rejected = expectLater(
      future,
      throwsA(isA<SessionCoordinationException>()),
    );
    await started.future;
    final logout = owner.signOut();
    response.complete('SYNTHETIC-SECRET');
    await rejected;
    await logout;
    expect(owner.session, isNull);
  });
  test('wrong handoff revision cannot expose recovery codes', () async {
    final owner = SessionOwner(Port());
    await owner.signIn('', '');
    addTearDown(owner.dispose);
    final api = SecurityApi(
      baseUrl: Uri.parse('http://localhost/'),
      owner: owner,
      client: MockClient(
        (_) async => json({
          'requestId': 'request',
          'revision': 99,
          'purpose': 'manage-issue',
          'accessToken': 'test',
          'refreshToken': 'test',
          'codes': ['SYNTHETIC'],
        }),
      ),
    );
    await expectLater(
      api.managementProof('issue-codes', 'request', 2, '123456'),
      throwsA(isA<SessionCoordinationException>()),
    );
    expect(owner.session, isNull);
  });
}
