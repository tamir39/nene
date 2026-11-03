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
import 'package:nene_app/data/banking_repository.dart';
import 'package:nene_app/data/confirmation_api.dart';
import 'package:nene_app/data/security_api.dart';
import 'package:nene_app/data/session_owner.dart';
import 'package:nene_app/ui/confirmation_screen.dart';
import 'package:nene_app/ui/nene_brand.dart';
import 'security_screen_test.dart' show Port;

const account = BankAccount(
  id: 'source',
  accountNumber: '100000000001',
  type: 'checking',
  currency: 'VND',
  balanceMinor: '0',
  status: 'active',
);
Map<String, dynamic> review() => {
  'reviewToken': 'synthetic-review',
  'requestId': 'request',
  'revision': 2,
  'sourceAccountNumber': account.accountNumber,
  'destinationAccountNumber': '100000000002',
  'amountMinor': '100000',
  'currency': 'VND',
  'feeMinor': '0',
  'expiresAt': DateTime.now()
      .add(const Duration(minutes: 10))
      .toIso8601String(),
  'sufficientFunds': false,
  'executionAvailable': false,
};
http.Response json(Object body) => http.Response(jsonEncode(body), 200);
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
  Future<http.Response> Function(http.Request) handler, {
  bool sendMoney = false,
}) async {
  tester.view.physicalSize = const Size(390, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final owner = SessionOwner(Port());
  await owner.signIn('', '');
  addTearDown(owner.dispose);
  final security = SecurityApi(
    baseUrl: Uri.parse('http://localhost/api/v1/'),
    client: MockClient(handler),
    owner: owner,
  );
  final theme = neneTheme();
  const capture = bool.fromEnvironment('CAPTURE_CONFIRMATION_UI');
  await tester.pumpWidget(
    MaterialApp(
      theme: theme.copyWith(
        textTheme: theme.textTheme.apply(
          fontFamily: capture ? 'ConfirmationTestFont' : null,
        ),
        filledButtonTheme: capture
            ? FilledButtonThemeData(
                style: theme.filledButtonTheme.style!.copyWith(
                  textStyle: const WidgetStatePropertyAll(
                    TextStyle(fontFamily: 'ConfirmationTestFont', fontSize: 16),
                  ),
                ),
              )
            : theme.filledButtonTheme,
      ),
      home: RepaintBoundary(
        key: const ValueKey('capture'),
        child: Scaffold(
          body: ConfirmationScreen(
            account: account,
            api: ConfirmationApi(security, sendMoney: sendMoney),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return owner;
}

Future<void> prepare(WidgetTester tester) async {
  await tester.enterText(find.byType(TextField).at(0), '100000000002');
  await tester.enterText(find.byType(TextField).at(1), '100000');
  await tap(tester, 'Review confirmation');
}

Future<void> captureTransfer(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('CAPTURE_CONFIRMATION_UI')) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('capture')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('../.tmp/confirmation-ui/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  testWidgets(
    'demo posting shows sent result, removes cancel, and recovers receipt on return',
    (tester) async {
      var sent = false;
      await showScreen(tester, (req) async {
        if (req.url.path.endsWith('/configuration')) {
          return json({'enabled': true});
        }
        if (req.url.path.endsWith('/transfers/')) {
          return json({
            'transfers': sent
                ? [
                    {
                      'requestId': 'request',
                      'state': 'posted',
                      'receipt': {'amountMinor': '100000'},
                    },
                  ]
                : <Map<String, dynamic>>[],
          });
        }
        if (req.url.path.endsWith('/security')) return json({'state': 'ready'});
        if (req.url.path.endsWith('/review')) {
          return json({
            ...review(),
            'sufficientFunds': true,
            'executionAvailable': true,
          });
        }
        expect(req.url.path.endsWith('/transfers/confirm'), true);
        sent = true;
        return json({
          'requestId': 'request',
          'revision': 2,
          'purpose': 'same-bank-transfer',
          'accessToken': 'test',
          'refreshToken': 'test',
          'state': 'posted',
          'sent': true,
          'executionAvailable': true,
          'replay': false,
        });
      }, sendMoney: true);
      await prepare(tester);
      await captureTransfer(tester, 'demo-transfer-review');
      await tester.enterText(find.byType(TextField), '123456');
      await tap(tester, 'Confirm and send demo funds');
      expect(find.textContaining('Demo transfer sent.'), findsOneWidget);
      expect(find.text('Cancel confirmation'), findsNothing);
      await captureTransfer(tester, 'demo-transfer-sent');
      await tap(tester, 'Start another transfer');
      expect(find.text('Sent 100000 VND · demo funds'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'uncertain demo response clears session and never claims transfer was not sent',
    (tester) async {
      final owner = await showScreen(tester, (req) async {
        if (req.url.path.endsWith('/configuration')) {
          return json({'enabled': true});
        }
        if (req.url.path.endsWith('/transfers/')) {
          return json({'transfers': <Map<String, dynamic>>[]});
        }
        if (req.url.path.endsWith('/security')) return json({'state': 'ready'});
        if (req.url.path.endsWith('/review')) {
          return json({...review(), 'sufficientFunds': true});
        }
        return http.Response('{}', 503);
      }, sendMoney: true);
      await prepare(tester);
      await tester.enterText(find.byType(TextField), '123456');
      await tap(tester, 'Confirm and send demo funds');
      expect(owner.session, isNull);
      expect(
        find.textContaining('Transfer outcome is unconfirmed.'),
        findsOneWidget,
      );
      expect(find.textContaining('Transfer not sent'), findsNothing);
      expect(find.text('Confirm and send demo funds'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('disabled local demo cannot request a review', (tester) async {
    await showScreen(
      tester,
      (req) async => req.url.path.endsWith('/configuration')
          ? json({'enabled': false})
          : json({'transfers': <Map<String, dynamic>>[]}),
      sendMoney: true,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Review confirmation'),
          )
          .onPressed,
      isNull,
    );
    expect(find.textContaining('not enabled'), findsOneWidget);
  });
  setUpAll(() async {
    if (!const bool.fromEnvironment('CAPTURE_CONFIRMATION_UI')) return;
    final sdk = Platform.environment['FLUTTER_ROOT'] ?? '../.tools/flutter';
    await (FontLoader('ConfirmationTestFont')..addFont(
          File(
            '$sdk/bin/cache/artifacts/material_fonts/roboto-regular.ttf',
          ).readAsBytes().then(ByteData.sublistView),
        ))
        .load();
  });
  testWidgets(
    'review binds displayed details and result never claims money was sent',
    (tester) async {
      var confirmations = 0;
      final owner = await showScreen(tester, (req) async {
        if (req.url.path.endsWith('/security')) return json({'state': 'ready'});
        if (req.url.path.endsWith('/review')) {
          expect(jsonDecode(req.body), {
            'sourceAccountId': 'source',
            'destinationAccountNumber': '100000000002',
            'amountMinor': '100000',
          });
          return json(review());
        }
        if (req.url.path.endsWith('/confirm')) {
          confirmations++;
          expect(jsonDecode(req.body), {
            'reviewToken': 'synthetic-review',
            'code': '123456',
          });
          return json({
            'requestId': 'request',
            'revision': 2,
            'purpose': 'transaction-confirmation',
            'accessToken': 'test',
            'refreshToken': 'test',
            'state': 'factor_confirmed',
            'sent': false,
            'executionAvailable': false,
            'replay': false,
          });
        }
        throw StateError('Unexpected route');
      });
      await prepare(tester);
      expect(find.text('To 100000000002'), findsOneWidget);
      expect(find.textContaining('Insufficient funds'), findsOneWidget);
      if (const bool.fromEnvironment('CAPTURE_CONFIRMATION_UI')) {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('capture')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('../.tmp/confirmation-ui/review.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.enterText(find.byType(TextField), '123456');
      await tap(tester, 'Check authenticator · do not send');
      expect(confirmations, 1);
      expect(owner.session, isNotNull);
      expect(
        find.text(
          'Authenticator checked for these details. Transfer not sent.',
        ),
        findsOneWidget,
      );
      expect(find.text('Check authenticator · do not send'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('editing cancels the old review before inputs become editable', (
    tester,
  ) async {
    var cancelled = false;
    await showScreen(tester, (req) async {
      if (req.url.path.endsWith('/security')) return json({'state': 'ready'});
      if (req.url.path.endsWith('/review')) return json(review());
      expect(req.url.path.endsWith('/cancel'), true);
      cancelled = true;
      return json({'state': 'cancelled'});
    });
    await prepare(tester);
    await tap(tester, 'Edit details / new review');
    expect(cancelled, true);
    expect(find.byType(TextField), findsNWidgets(2));
    expect(find.text('100000'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'rejected proof is not retried and background clears entered code',
    (tester) async {
      var attempts = 0;
      final owner = await showScreen(tester, (req) async {
        if (req.url.path.endsWith('/security')) return json({'state': 'ready'});
        if (req.url.path.endsWith('/review')) return json(review());
        if (req.url.path.endsWith('/confirm')) {
          attempts++;
          return http.Response('{}', 400);
        }
        return json({
          'state': 'rejected',
          'sent': false,
          'executionAvailable': false,
        });
      });
      await prepare(tester);
      await tester.enterText(find.byType(TextField), '123456');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(find.byType(TextField), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      await tester.enterText(find.byType(TextField), '123456');
      await tap(tester, 'Check authenticator · do not send');
      expect(owner.session, isNotNull);
      expect(attempts, 1);
      expect(find.text('Check authenticator · do not send'), findsNothing);
      await tap(tester, 'Check confirmation status');
      expect(
        find.text('Code not accepted. Start a new review with a fresh code.'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'missing authenticator directs customer to setup without signing out',
    (tester) async {
      final owner = await showScreen(
        tester,
        (_) async => json({'state': 'not_set_up'}),
      );
      await prepare(tester);
      expect(find.textContaining('Finish authenticator setup'), findsOneWidget);
      expect(owner.session, isNotNull);
    },
  );
  test('forged review binding cannot adopt the provider pair', () async {
    final owner = SessionOwner(Port());
    await owner.signIn('', '');
    addTearDown(owner.dispose);
    final api = ConfirmationApi(
      SecurityApi(
        baseUrl: Uri.parse('http://localhost/'),
        owner: owner,
        client: MockClient(
          (_) async => json({
            'requestId': 'different',
            'revision': 2,
            'purpose': 'transaction-confirmation',
            'accessToken': 'test',
            'refreshToken': 'test',
            'state': 'factor_confirmed',
            'sent': false,
            'executionAvailable': false,
            'replay': false,
          }),
        ),
      ),
    );
    await expectLater(
      api.confirm(review(), '123456'),
      throwsA(isA<SessionCoordinationException>()),
    );
    expect(owner.session, isNull);
  });
  test('delayed review after logout is not delivered to the screen', () async {
    final owner = SessionOwner(Port());
    await owner.signIn('', '');
    addTearDown(owner.dispose);
    final response = Completer<http.Response>(), started = Completer<void>();
    final api = ConfirmationApi(
      SecurityApi(
        baseUrl: Uri.parse('http://localhost/'),
        owner: owner,
        client: MockClient((_) {
          started.complete();
          return response.future;
        }),
      ),
    );
    final pending = api.review('source', '100000000002', '100000');
    final rejected = expectLater(
      pending,
      throwsA(isA<SessionCoordinationException>()),
    );
    await started.future;
    final logout = owner.signOut();
    response.complete(json(review()));
    await rejected;
    await logout;
  });
}
