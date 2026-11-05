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
import 'package:nene_app/data/payments_api.dart';
import 'package:nene_app/data/security_api.dart';
import 'package:nene_app/data/session_owner.dart';
import 'package:nene_app/ui/payments_screen.dart';
import 'package:nene_app/ui/nene_brand.dart';
import 'security_screen_test.dart' show Port;

Map<String, dynamic> service([String id = 'electricity']) => {
  'id': id,
  'name': switch (id) {
    'electricity' => 'Demo electricity bill',
    'water' => 'Demo water bill',
    _ => 'Demo phone top-up',
  },
  'description':
      'Fictional Nene service. No real bill or phone credit is delivered.',
  'amountMinor': switch (id) {
    'electricity' => '200000',
    'water' => '100000',
    _ => '50000',
  },
  'currency': 'VND',
};
Map<String, dynamic> configuration({bool enabled = true}) => {
  'enabled': enabled,
  'services': [service(), service('water'), service('phone')],
  'fulfillment': 'not_available',
};
Map<String, dynamic> review() => {
  'reviewToken': 'synthetic-signed-review',
  'requestId': 'payment-request',
  'revision': 2,
  'service': service(),
  'amountMinor': '200000',
  'currency': 'VND',
  'expiresAt': DateTime.now()
      .add(const Duration(minutes: 10))
      .toIso8601String(),
};
Map<String, dynamic> order([String state = 'awaiting_payment']) => {
  'id': 'payment-request',
  'service': service(),
  'amountMinor': '200000',
  'currency': 'VND',
  'state': state,
  'createdAt': DateTime.now().toIso8601String(),
  'expiresAt': DateTime.now()
      .add(const Duration(minutes: 15))
      .toIso8601String(),
  'paidAt': null,
  'fulfillment': 'not_available',
};
const checkout =
    'https://sandbox.vnpayment.vn/paymentv2/vpcpay.html?vnp_TxnRef=synthetic';
Map<String, dynamic> confirm() => {
  'requestId': 'payment-request',
  'revision': 2,
  'purpose': 'vnpay-checkout',
  'accessToken': 'new-access',
  'refreshToken': 'new-refresh',
  'replay': false,
  'state': 'awaiting_payment',
  'order': order(),
  'checkoutUrl': checkout,
};
http.Response json(Object data, [int status = 200]) =>
    http.Response(jsonEncode(data), status);
Future<PaymentsApi> createApi(
  Future<http.Response> Function(http.Request) handler,
) async {
  final owner = SessionOwner(Port());
  await owner.signIn('', '');
  addTearDown(owner.dispose);
  return PaymentsApi(
    SecurityApi(
      baseUrl: Uri.parse('http://localhost/api/v1/'),
      client: MockClient(handler),
      owner: owner,
    ),
  );
}

Future<void> tap(WidgetTester tester, String label) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text(label));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

Future<void> showScreen(
  WidgetTester tester,
  PaymentsApi api, {
  Future<bool> Function(Uri)? open,
  bool capture = false,
}) async {
  tester.view.physicalSize = const Size(390, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final theme = neneTheme();
  await tester.pumpWidget(
    MaterialApp(
      theme: capture
          ? theme.copyWith(
              textTheme: theme.textTheme.apply(
                fontFamily: 'PaymentFixtureFont',
              ),
              filledButtonTheme: FilledButtonThemeData(
                style: theme.filledButtonTheme.style!.copyWith(
                  textStyle: const WidgetStatePropertyAll(
                    TextStyle(
                      fontFamily: 'PaymentFixtureFont',
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            )
          : theme,
      home: RepaintBoundary(
        key: const ValueKey('payment-capture'),
        child: Scaffold(
          appBar: AppBar(title: const NeneLogo(size: 30)),
          body: PaymentsScreen(api: api, openCheckout: open),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('checkout navigation permits only the exact HTTPS sandbox endpoint', () {
    expect(checkedCheckoutUrl(checkout).host, 'sandbox.vnpayment.vn');
    for (final value in [
      'http://sandbox.vnpayment.vn/paymentv2/vpcpay.html?q=1',
      'https://sandbox.vnpayment.vn.example.invalid/paymentv2/vpcpay.html?q=1',
      'https://example.invalid/paymentv2/vpcpay.html?q=1',
      'https://token@sandbox.vnpayment.vn/paymentv2/vpcpay.html?q=1',
      'https://sandbox.vnpayment.vn:444/paymentv2/vpcpay.html?q=1',
      'https://sandbox.vnpayment.vn/other?q=1',
      'https://sandbox.vnpayment.vn/paymentv2/vpcpay.html',
      '$checkout#fragment',
      'javascript:alert(1)',
      null,
    ]) {
      expect(
        () => checkedCheckoutUrl(value),
        throwsA(isA<SessionCoordinationException>()),
      );
    }
  });
  test(
    'confirmation adopts only a matching purpose/request/revision and exact reviewed service',
    () async {
      for (final change in [
        <String, dynamic>{},
        {'purpose': 'same-bank-transfer'},
        {'requestId': 'different'},
        {'revision': 3},
        {'state': 'paid'},
        {
          'order': {
            ...order(),
            'service': service('phone'),
            'amountMinor': '50000',
          },
        },
        {'checkoutUrl': 'https://example.invalid/steal'},
      ]) {
        final api = await createApi((req) async {
          expect(req.followRedirects, isFalse);
          if (req.url.path.endsWith('/review')) return json(review());
          expect(jsonDecode(req.body), {
            'reviewToken': 'synthetic-signed-review',
            'code': '123456',
          });
          return json({...confirm(), ...change});
        });
        final prepared = await api.review('electricity');
        if (change.isEmpty) {
          final result = await api.confirm(prepared, '123456');
          expect(result.state, 'awaiting_payment');
          expect(api.security.owner.session!.pair.accessToken, 'new-access');
        } else {
          await expectLater(
            api.confirm(prepared, '123456'),
            throwsA(isA<SessionCoordinationException>()),
          );
          expect(api.security.owner.session, isNull);
        }
      }
    },
  );
  test(
    'duplicate confirmation consumes no returned credentials and preserves current session',
    () async {
      final api = await createApi(
        (req) async => req.url.path.endsWith('/review')
            ? json(review())
            : json({
                'requestId': 'payment-request',
                'state': 'paid',
                'replay': true,
                'order': order('paid'),
              }),
      );
      final prepared = await api.review('electricity');
      expect((await api.confirm(prepared, '123456')).state, 'paid');
      expect(api.security.owner.session!.pair.accessToken, 'test');
    },
  );
  test(
    'definite pre-provider rejection retains session while ambiguous failure clears it',
    () async {
      for (final status in [409, 503]) {
        final api = await createApi(
          (req) async => req.url.path.endsWith('/review')
              ? json(review())
              : json({}, status),
        );
        final prepared = await api.review('electricity');
        await expectLater(
          api.confirm(prepared, '123456'),
          throwsA(
            status == 409
                ? isA<SessionMutationRejected>()
                : isA<SessionCoordinationException>(),
          ),
        );
        expect(api.security.owner.session == null, status == 503);
      }
    },
  );
  test(
    'another order or fulfillment claim cannot be accepted as this payment status',
    () async {
      for (final changed in [
        {...order(), 'id': 'someone-else'},
        {...order(), 'fulfillment': 'delivered'},
        {...order(), 'amountMinor': '1'},
      ]) {
        final api = await createApi(
          (_) async => json({
            'requestId': 'payment-request',
            'state': changed['state'],
            'order': changed,
          }),
        );
        await expectLater(
          api.status('payment-request'),
          throwsA(isA<SessionCoordinationException>()),
        );
      }
    },
  );
  test(
    'attempt-only status must name the requested operation and cannot claim payment success',
    () async {
      for (final data in [
        {'requestId': 'another-request', 'state': 'unknown', 'order': null},
        {'requestId': 'payment-request', 'state': 'paid', 'order': null},
        {
          'requestId': 'payment-request',
          'state': 'failed',
          'order': order('paid'),
        },
      ]) {
        final api = await createApi((_) async => json(data));
        await expectLater(
          api.status('payment-request'),
          throwsA(isA<SessionCoordinationException>()),
        );
      }
    },
  );
  testWidgets(
    'disabled sandbox shows labelled catalog and never posts or launches',
    (tester) async {
      final paths = <String>[];
      final api = await createApi((req) async {
        expect(req.method, 'GET');
        paths.add(req.url.path);
        return json(
          req.url.path.endsWith('/configuration')
              ? configuration(enabled: false)
              : {'orders': <Map<String, dynamic>>[]},
        );
      });
      await showScreen(tester, api, open: (_) async => fail('must not open'));
      expect(find.text('Sandbox setup pending'), findsOneWidget);
      expect(find.text('Demo electricity bill'), findsOneWidget);
      expect(find.text('Demo water bill'), findsOneWidget);
      expect(find.text('Demo phone top-up'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Review electricity bill'),
            )
            .onPressed,
        isNull,
      );
      expect(paths, [
        '/api/v1/me/payments/configuration',
        '/api/v1/me/payments/',
      ]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'explicit review, authenticator and launch remain separate; callback status is not fulfillment',
    (tester) async {
      final posts = <String>[];
      var opened = 0;
      final api = await createApi((req) async {
        if (req.url.path.endsWith('/configuration')) {
          return json(configuration());
        }
        if (req.url.path.endsWith('/payments/')) {
          return json({'orders': <Map<String, dynamic>>[]});
        }
        if (req.method == 'POST') posts.add(req.url.path);
        if (req.url.path.endsWith('/review')) return json(review());
        if (req.url.path.endsWith('/confirm')) return json(confirm());
        expect(req.headers['authorization'], 'Bearer new-access');
        return json({
          'requestId': 'payment-request',
          'state': 'paid',
          'order': order('paid'),
        });
      });
      await showScreen(
        tester,
        api,
        open: (uri) async {
          expect(uri.toString(), checkout);
          opened++;
          return true;
        },
      );
      expect(posts, isEmpty);
      await tap(tester, 'Review electricity bill');
      expect(posts, ['/api/v1/me/payments/review']);
      expect(opened, 0);
      expect(find.text('200,000 VND'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '123456');
      await tap(tester, 'Confirm sandbox checkout');
      expect(posts.length, 2);
      expect(opened, 0);
      expect(find.text('Waiting for sandbox payment'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      await tap(tester, 'Open VNPay sandbox');
      expect(opened, 1);
      expect(find.text('Sandbox payment successful'), findsNothing);
      await tap(tester, 'Check payment status');
      expect(find.text('Sandbox payment successful'), findsOneWidget);
      expect(
        find.textContaining(
          'this did not settle a bill or deliver phone credit',
        ),
        findsOneWidget,
      );
      expect(find.text('Open VNPay sandbox'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'uncertain confirmation offers status but cannot repeat proof or create checkout',
    (tester) async {
      var confirms = 0;
      final api = await createApi((req) async {
        if (req.url.path.endsWith('/configuration')) {
          return json(configuration());
        }
        if (req.url.path.endsWith('/payments/')) {
          return json({'orders': <Map<String, dynamic>>[]});
        }
        if (req.url.path.endsWith('/review')) return json(review());
        confirms++;
        return json({}, 503);
      });
      await showScreen(tester, api);
      await tap(tester, 'Review electricity bill');
      await tester.enterText(find.byType(TextField), '123456');
      await tap(tester, 'Confirm sandbox checkout');
      expect(confirms, 1);
      expect(find.text('Confirmation outcome unknown'), findsOneWidget);
      expect(find.text('Confirm sandbox checkout'), findsNothing);
      expect(find.text('Back to demo services'), findsNothing);
      expect(find.text('Open VNPay sandbox'), findsNothing);
      expect(api.security.owner.session, isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('expired review clears the code and cannot confirm', (
    tester,
  ) async {
    final api = await createApi((req) async {
      if (req.url.path.endsWith('/configuration')) return json(configuration());
      if (req.url.path.endsWith('/payments/')) {
        return json({'orders': <Map<String, dynamic>>[]});
      }
      return json({
        ...review(),
        'expiresAt': DateTime.now()
            .add(const Duration(seconds: 2))
            .toIso8601String(),
      });
    });
    await showScreen(tester, api);
    await tap(tester, 'Review electricity bill');
    await tester.enterText(find.byType(TextField), '123456');
    await tester.pump(const Duration(seconds: 3));
    expect(find.textContaining('This review expired.'), findsOneWidget);
    expect(find.text('Confirm sandbox checkout'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('disposal and sign-out discard a late review', (tester) async {
    final pending = Completer<http.Response>();
    final api = await createApi((req) async {
      if (req.url.path.endsWith('/configuration')) return json(configuration());
      if (req.url.path.endsWith('/payments/')) {
        return json({'orders': <Map<String, dynamic>>[]});
      }
      return pending.future;
    });
    await showScreen(tester, api);
    await tester.ensureVisible(find.text('Review electricity bill'));
    await tester.tap(find.text('Review electricity bill'));
    await tester.pump();
    final logout = api.security.owner.signOut();
    await tester.pumpWidget(const SizedBox());
    pending.complete(json(review()));
    await tester.pumpAndSettle();
    await logout;
    expect(api.security.owner.session, isNull);
    expect(tester.takeException(), isNull);
  });
  testWidgets('renders a narrow synthetic sandbox review fixture', (
    tester,
  ) async {
    if (!const bool.fromEnvironment('CAPTURE_PAYMENTS_UI')) return;
    final sdk = Platform.environment['FLUTTER_ROOT'] ?? '../.tools/flutter';
    await tester.runAsync(() async {
      for (final font in {
        'PaymentFixtureFont': 'roboto-regular.ttf',
        'MaterialIcons': 'MaterialIcons-Regular.otf',
      }.entries) {
        await (FontLoader(font.key)..addFont(
              File(
                '$sdk/bin/cache/artifacts/material_fonts/${font.value}',
              ).readAsBytes().then(ByteData.sublistView),
            ))
            .load();
      }
    });
    var enabled = false;
    final api = await createApi((req) async {
      if (req.url.path.endsWith('/configuration')) {
        return json(configuration(enabled: enabled));
      }
      if (req.url.path.endsWith('/payments/')) {
        return json({'orders': <Map<String, dynamic>>[]});
      }
      return json(review());
    });
    await showScreen(tester, api, capture: true);
    Future<void> capture(String name) async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('payment-capture')),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('../.tmp/ui-review/$name.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    await capture('payments-disabled-fixture');
    enabled = true;
    await tap(tester, 'Refresh services & payments');
    await tap(tester, 'Review electricity bill');
    await capture('payments-fixture');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
