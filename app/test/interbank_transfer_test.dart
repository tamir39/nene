import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nene_app/data/confirmation_api.dart';
import 'package:nene_app/data/security_api.dart';
import 'package:nene_app/data/session_owner.dart';
import 'package:nene_app/nene_app.dart';
import 'package:nene_app/session_controller.dart';
import 'package:nene_app/ui/confirmation_screen.dart';
import 'confirmation_screen_test.dart' as fixture;
import 'security_screen_test.dart' show Port;
import 'assistant_test.dart' as chat_fixture;
import 'test_doubles.dart';

Map<String, dynamic> configuration({bool enabled = true}) => {
  'enabled': enabled,
  'simulated': true,
  'currency': 'VND',
  'highValueThresholdMinor': '5000000',
  'banks': [
    for (final suffix in ['A', 'B'])
      {
        'code': 'DEMO_$suffix',
        'name': 'Demo Bank $suffix',
        'recipients': [
          {
            'accountNumber': suffix == 'A' ? '990000000001' : '990000000002',
            'name': 'Demo recipient $suffix',
          },
        ],
      },
  ],
};
Map<String, dynamic> review() => {
  ...fixture.review(),
  'destinationAccountNumber': '990000000001',
  'destinationBankCode': 'DEMO_A',
  'destinationBankName': 'Demo Bank A',
  'destinationRecipientName': 'Demo recipient A',
  'simulated': true,
  'sufficientFunds': true,
  'executionAvailable': true,
};
Map<String, dynamic> receipt() => {
  'id': 'receipt',
  'amountMinor': '100000',
  'currency': 'VND',
  'postedAt': '2026-11-07T01:00:00Z',
  'sourceAccountId': 'source',
  'destinationBankCode': 'DEMO_A',
  'destinationBankName': 'Demo Bank A',
  'destinationAccountNumber': '990000000001',
  'destinationRecipientName': 'Demo recipient A',
  'simulated': true,
};
Map<String, dynamic> posted({bool replay = false}) => {
  'requestId': 'request',
  'revision': 2,
  'purpose': 'interbank-transfer',
  if (!replay) ...{'accessToken': 'test', 'refreshToken': 'test'},
  'state': 'posted',
  'sent': true,
  'executionAvailable': true,
  'simulated': true,
  'replay': replay,
  'receipt': receipt(),
};
Future<void> select(WidgetTester tester, String bank, String recipient) async {
  await tester.tap(find.byType(DropdownButtonFormField<String>).first);
  await tester.pumpAndSettle();
  await tester.tap(find.text(bank).last);
  await tester.pumpAndSettle();
  await tester.tap(find.byType(DropdownButtonFormField<String>).last);
  await tester.pumpAndSettle();
  await tester.tap(find.text(recipient).last);
  await tester.pumpAndSettle();
}

Future<void> prepare(WidgetTester tester) async {
  await select(tester, 'Demo Bank A', 'Demo recipient A · 990000000001');
  await tester.enterText(find.byType(TextField), '100000');
  await fixture.tap(tester, 'Review confirmation');
}

void main() {
  testWidgets(
    'home opens interbank flow and refreshes accounts on return without leaking its mode',
    (tester) async {
      final session = SessionController(
        auth: FakeAuth()
          ..userId = demoProfile.id
          ..accessToken = 'test-token',
        profiles: FakeProfiles(),
      );
      await session.loadProfile();
      final credentials = SessionOwner(Port());
      await credentials.signIn('', '');
      addTearDown(credentials.dispose);
      final banking = FakeBanking();
      await tester.pumpWidget(
        NeneApp(
          controller: session,
          banking: banking,
          security: SecurityApi(
            baseUrl: Uri.parse('http://localhost/api/v1/'),
            owner: credentials,
            client: MockClient((req) async {
              expect(req.method, 'GET');
              return fixture.json(
                req.url.path.endsWith('/configuration')
                    ? configuration()
                    : {'transfers': <Map<String, dynamic>>[]},
              );
            }),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(banking.accountsCalls, 1);
      await chat_fixture.tap(tester, 'Other-bank demo transfer');
      expect(
        tester
            .widget<ConfirmationScreen>(find.byType(ConfirmationScreen))
            .api
            .interbank,
        isTrue,
      );
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(banking.accountsCalls, 2);
      await chat_fixture.tap(tester, 'Transfer demo funds');
      expect(
        tester
            .widget<ConfirmationScreen>(find.byType(ConfirmationScreen))
            .api
            .interbank,
        isFalse,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
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
    'fictional bank selection, bound review, labelled posting and receipt recovery',
    (tester) async {
      var confirmed = false;
      final owner = await fixture.showScreen(tester, (req) async {
        if (req.url.path.endsWith('/configuration')) {
          return fixture.json(configuration());
        }
        if (req.url.path.endsWith('/interbank-transfers/')) {
          return fixture.json({
            'transfers': confirmed
                ? [posted(replay: true)]
                : <Map<String, dynamic>>[],
          });
        }
        if (req.url.path.endsWith('/security')) {
          return fixture.json({'state': 'ready'});
        }
        if (req.url.path.endsWith('/review')) {
          expect(req.url.path, '/api/v1/me/interbank-transfers/review');
          expect(jsonDecode(req.body), {
            'sourceAccountId': 'source',
            'destinationBankCode': 'DEMO_A',
            'destinationAccountNumber': '990000000001',
            'amountMinor': '100000',
          });
          return fixture.json(review());
        }
        if (req.url.path.endsWith('/confirm')) confirmed = true;
        return fixture.json(posted());
      }, interbank: true);
      expect(find.text('Other-bank demo transfer'), findsOneWidget);
      expect(find.text('Recipient Nene account number'), findsNothing);
      await select(tester, 'Demo Bank B', 'Demo recipient B · 990000000002');
      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Demo Bank A').last);
      await tester.pumpAndSettle();
      expect(find.text('Demo recipient B · 990000000002'), findsNothing);
      await tester.enterText(find.byType(TextField), '100000');
      await fixture.tap(tester, 'Review confirmation');
      expect(find.textContaining('Choose a fictional bank'), findsOneWidget);
      await prepare(tester);
      expect(find.text('Fictional bank: Demo Bank A'), findsOneWidget);
      expect(find.text('Demo recipient: Demo recipient A'), findsOneWidget);
      expect(find.text('To 990000000001'), findsOneWidget);
      await fixture.captureTransfer(tester, 'interbank-review');
      await tester.enterText(find.byType(TextField), '123456');
      await fixture.tap(tester, 'Confirm simulated transfer');
      expect(owner.session, isNotNull);
      expect(
        find.textContaining('No real bank received a payment.'),
        findsOneWidget,
      );
      await fixture.captureTransfer(tester, 'interbank-posted');
      await fixture.tap(tester, 'Start another transfer');
      await fixture.tap(tester, 'Simulated 100000 VND · demo funds');
      expect(find.text('Demo recipient: Demo recipient A'), findsOneWidget);
      expect(find.text('Confirm simulated transfer'), findsNothing);
      expect(find.text('Cancel confirmation'), findsNothing);
      expect(find.text('Back to recent transfers'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'uncertain interbank result clears session and never claims delivery',
    (tester) async {
      final owner = await fixture.showScreen(tester, (req) async {
        if (req.url.path.endsWith('/configuration')) {
          return fixture.json(configuration());
        }
        if (req.url.path.endsWith('/interbank-transfers/')) {
          return fixture.json({'transfers': <Map<String, dynamic>>[]});
        }
        if (req.url.path.endsWith('/security')) {
          return fixture.json({'state': 'ready'});
        }
        if (req.url.path.endsWith('/review')) return fixture.json(review());
        return http.Response('{}', 503);
      }, interbank: true);
      await prepare(tester);
      await tester.enterText(find.byType(TextField), '123456');
      await fixture.tap(tester, 'Confirm simulated transfer');
      expect(owner.session, isNull);
      expect(find.textContaining('Simulated delivery recorded.'), findsNothing);
      expect(find.textContaining('Do not send it again'), findsOneWidget);
      expect(find.text('Confirm simulated transfer'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final mutation in [
    {'purpose': 'same-bank-transfer'},
    {'simulated': false},
    {'requestId': 'another-proof'},
    {
      'receipt': {...receipt(), 'simulated': false},
    },
    {
      'receipt': {...receipt(), 'destinationBankCode': 'DEMO_B'},
    },
  ]) {
    test('interbank rejects mismatched confirmation $mutation', () async {
      final owner = SessionOwner(Port());
      await owner.signIn('', '');
      addTearDown(owner.dispose);
      final api = ConfirmationApi(
        SecurityApi(
          baseUrl: Uri.parse('http://localhost/api/v1/'),
          owner: owner,
          client: MockClient(
            (req) async => fixture.json({...posted(), ...mutation}),
          ),
        ),
        interbank: true,
      );
      await expectLater(
        api.confirm(review(), '123456'),
        throwsA(isA<SessionCoordinationException>()),
      );
      expect(owner.session, isNull);
    });
  }
  test(
    'interbank status replay never adopts another provider session',
    () async {
      final owner = SessionOwner(Port());
      await owner.signIn('', '');
      addTearDown(owner.dispose);
      final api = ConfirmationApi(
        SecurityApi(
          baseUrl: Uri.parse('http://localhost/api/v1/'),
          owner: owner,
          client: MockClient((req) async => fixture.json(posted(replay: true))),
        ),
        interbank: true,
      );
      final result = await api.confirm(review(), '123456');
      expect(result['state'], 'posted');
      expect(owner.session?.pair.accessToken, 'test');
    },
  );
  testWidgets('disabled interbank configuration cannot request a review', (
    tester,
  ) async {
    await fixture.showScreen(tester, (req) async {
      expect(req.method, 'GET');
      return fixture.json(
        req.url.path.endsWith('/configuration')
            ? configuration(enabled: false)
            : {'transfers': <Map<String, dynamic>>[]},
      );
    }, interbank: true);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Review confirmation'),
          )
          .onPressed,
      isNull,
    );
    await tester.pumpWidget(const SizedBox());
  });
  test(
    'interbank rejects review substitution and unlabelled configuration',
    () async {
      final owner = SessionOwner(Port());
      await owner.signIn('', '');
      addTearDown(owner.dispose);
      final api = ConfirmationApi(
        SecurityApi(
          baseUrl: Uri.parse('http://localhost/api/v1/'),
          owner: owner,
          client: MockClient(
            (req) async => fixture.json(
              req.url.path.endsWith('/configuration')
                  ? {...configuration(), 'simulated': false}
                  : {...review(), 'destinationBankCode': 'DEMO_B'},
            ),
          ),
        ),
        interbank: true,
      );
      await expectLater(
        api.configuration(),
        throwsA(isA<SessionCoordinationException>()),
      );
      await expectLater(
        api.review(
          'source',
          '990000000001',
          '100000',
          destinationBankCode: 'DEMO_A',
        ),
        throwsA(isA<SessionCoordinationException>()),
      );
    },
  );
}
